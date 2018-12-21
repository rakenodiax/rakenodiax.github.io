---
title: "Exploring The Gotham Web Framework"
date: 2018-12-04T10:18:59+01:00
tags: [ "rust", "gotham", "web", "framework" ]
categories: [ "programming" ]
layout: post
type: "post"
draft: true
---

## Intro

[Gotham](https://gotham.rs/) recently released `v0.3`, which is the first release by its new core team. I feel this is a pretty underrated framework in the Rust ecosystem: [according to the most recent Rust Web Survey](https://rust-lang-nursery.github.io/wg-net/2018/11/28/wg-net-survey.html), Gotham is used by 2.2% of respondents, compared to 27% and 24% for [Rocket](https://rocket.rs/) and [Actix Web](https://actix.rs/), respectively.

Gotham uses a `State` struct which is used for everything from path segments to middleware. It's very elegant to have this state "threading" through the response lifecycle, and quite intuitive, too. Gotham leverages its [`borrow-bag`](https://crates.io/crates/borrow-bag) crate to access state, e.g.:

{{< highlight rust "hl_lines=11" >}}
// imports elided

/// This is the type we use to represent "the `name` parameter from the request"
#[derive(Deserialize, StateData)]
struct NameExtractor {
    name: String
}

fn say_hello(state: State) -> (State, impl IntoResponse) {
    let res = {
        let query_param = NameExtractor::borrow_from(&state);

        let greeting = format!("Hello, {}", query_param.name);

        create_response(&state, StatusCode::OK, mime::TEXT_PLAIN, greeting)
    };

    (state, res)
}
{{< / highlight>}}

I'm going to write up an exploration of using the Gotham web framework in making a simple note taking app. Notebooks will be protected behind a password and given a unique URL. This post assumes a basic understanding of [The Rust Programming Language](https://doc.rust-lang.org/book/second-edition/index.html), but I'll be explaining my thought process along the way. I will be using version `1.31.0` and code will be in `Edition 2018`.

## Starting at the beginning, with data

I like to start building my CRUD-like apps in the center, with the data I want to present, process, store, etc. We already know that this app will be storing Notes. These Notes will be associated with and collected by Notebook. These are the two main data structures in our app, so let's fire up a new *crate* and write up these structures:

{{< highlight sh >}}
# Start the crate as a core library, and then worry about execution once the app is functional
$ cargo new notes --lib && cd notes
# Chrono is the date and time framework we'll use for this app
$ echo 'chrono = { version = "0.4.6", features = ["serde"] }' >> Cargo.toml
{{< / highlight >}}

In `src/lib.rs`:

{{< highlight rust "linenos=table" >}}
use chrono::prelude::*;

#[derive(Debug, Default, Hash)]
pub struct Note {
    id: i32,
    notebook_id: i32,
    title: String,
    body: String,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

#[derive(Debug, Default, Hash)]
pub struct NoteBook {
    id: i32,
    slug: String,
    notes: Vec<Note>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}
{{< / highlight >}}

## Setting up Diesel

The data must be persisted in some way, and the easiest way is with [`diesel`](https://diesel.rs/). The `diesel` ORM (or, SRM if you're being pedantic 🙂) provides a lot of nice helpers for building queries, inserting data, and generally making database interaction that much easier. We're going to use an `sqlite` database for simplicity, but `postgresql` and `mysql` are also supported out of the box.

The [Diesel Getting Started Guide](http://diesel.rs/guides/getting-started/) is a great place to start if you aren't familiar with the library. The following with set up `diesel` to work with a local `sqlite` database:

{{< highlight sh >}}
$ echo 'diesel = { version = "1.3.3", features = ["sqlite", "chrono"] }' >> Cargo.toml
$ echo 'DATABASE_URL=file:notes.db' > .env
$ echo '/.env' >> .gitignore
$ diesel setup
$ echo '/notes.db' >> .gitignore
{{< / highlight >}}

We're going to keep database-related code in the `db` module, so we configure `diesel.toml` to print the schema to that directory:

```
[print_schema]
file = "src/db/schema.rs"
```

Now we generate our migrations for Notes and Notebooks with `diesel migration generate create-notebooks` and modify `migrations/YYYY-MM-DD-SSSSSS_create-notebooks/up.sql`:

{{< highlight sql "linenos=table" >}}
CREATE TABLE notebooks (
    id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    slug TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE notes (
    id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    notebook_id INTEGER NOT NULL,
    title TEXT NOT NULL,
    body TEXT NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY(notebook_id) REFERENCES notebooks(id)
);
{{< / highlight >}}

And the corresponding `down.sql`:

{{< highlight sql "linenos=table" >}}
DROP TABLE notes;
DROP TABLE notebooks;
{{< / highlight >}}

Now run `diesel migration run` and verify the printed schema in `src/db/schema.rs`:

{{< highlight rust "linenos=table" >}}
table! {
    notebooks (id) {
        id -> Integer,
        slug -> Text,
        password_hash -> Text,
        created_at -> Timestamp,
    }
}

table! {
    notes (id) {
        id -> Integer,
        notebook_id -> Integer,
        title -> Text,
        body -> Text,
        created_at -> Timestamp,
    }
}

joinable!(notes -> notebooks (notebook_id));

allow_tables_to_appear_in_same_query!(
    notebooks,
    notes,
);
{{< / highlight >}}

> **Note:** Due to the behavior of the `diesel` cli, *all* of `diesel`'s macros must be imported at the crate root, just like the good ol' days. There is [currently an issue](https://github.com/diesel-rs/diesel/issues/1764) on GitHub, but this behavior is unlikely to be updated. This should be the only legacy `macro_use` delcaration we need to do in this app.

{{< highlight rust "linenos=table" >}}
#[macro_use] extern crate diesel;
{{< / highlight >}}

## Access through our Data layer

We're going to use methods on our `Notebook` struct to control access to protected notebooks. Each Notebook is password protected, so we want to make sure that creating one sets the password, and reading requires the password to be valid. 

{{< highlight rust "linenos=table,linenostart=21" >}}
impl Notebook {
    /// Uses the provided connection to create a new Notebook protected by the given password. A random slug is generated for access later.
    pub fn new(
        conn: &impl Connection<Backend = Sqlite>,
        slug: &str,
        plaintext_password: &str,
    ) -> Result<Notebook, Box<dyn std::error::Error>> {
        // The password is hashed into a `String`, or an error is propagated if something went wrong in the hashing library
        let password_hash = hash_password(plaintext_password)?;

        // `db::models::Notebook` handles the database insertion
        let created = NotebookModel::create(conn, &slug, &password_hash)?;

        // `Notebook implements From<db::models::Notebook>`
        Ok(created.into())
    }
}
{{< / highlight >}}

Trying to run `cargo check` on this code will lead to a slew of warnings and errors. We're using the compiler to guide our imlementation.

```
error[E0433]: failed to resolve: use of undeclared type or module `NotebookModel`
  --> src/lib.rs:30:23
   |
30 |         let created = NotebookModel::create(&slug, &password_hash)?;
   |                       ^^^^^^^^^^^^^ use of undeclared type or module `NotebookModel`

error[E0425]: cannot find function `hash_password` in this scope
  --> src/lib.rs:27:29
   |
27 |         let password_hash = hash_password(plaintext_password)?;
   |                             ^^^^^^^^^^^^^ not found in this scope
```

First off, `diesel`'s use of macros is currently deprecated; to silence these warnings, add `#![allow(proc_macro_derive_resolution_fallback)]` to the top of your `src/lib.rs` file. Now, let's `use` the two missing items:

{{< highlight rust "linenos=table,linenostart=2" >}}
use self::db::models::Notebook as NotebookModel;
use self::auth::hash_password;

mod auth;
mod db;
{{< / highlight >}}

We'll define an empty model in `src/db/models.rs`:

{{< highlight rust "linenos=table" >}}
use diesel::prelude::*;
use diesel::sqlite::Sqlite;

pub(crate) struct Notebook;

impl Notebook {
    pub fn create(
        conn: &impl Connection<Backend = Sqlite>,
        slug: &str,
        password_hash: &str,
    ) -> Result<Notebook, Box<dyn std::error::Error>> {
        unimplemented!();
    }
}
{{< / highlight >}}

...and our password hashing function in `src/auth.rs`:

{{< highlight rust "linenos=table" >}}
/// Takes a plaintext password and returns an irreversable hash of the input, passing any hashing errors up to the caller
pub fn hash_password(plaintext_password: &str) -> Result<String, Box<dyn std::error::Error>> {
    // TODO: implement actual hashing
    Ok(plaintext_password.chars().rev().collect())
}
{{< / highlight >}}

The error from `rustc` tells us where to go next:

```
error[E0277]: the trait bound `Notebook: std::convert::From<db::models::Notebook>` is not satisfied
  --> src/lib.rs:45:20
   |
45 |         Ok(created.into())
   |                    ^^^^ the trait `std::convert::From<db::models::Notebook>` is not implemented for `Notebook`
```

Implementing `models::Notebook -> Notebook` is pretty simple. In `src/db/models.rs`:

{{< highlight rust "linenos=table,hl_lines=1-2 4-10" >}}
use diesel::prelude::*;
use chrono::prelude::*;
use diesel::sqlite::Sqlite;
use crate::Notebook as NotebookData;

pub(crate) struct Notebook {
    id: i32,
    slug: String,
    password_hash: String,
    created_at: NaiveDateTime,
}
{{< / highlight >}}
{{< highlight rust "linenos=table,linenostart=22,hl_lines=1-10" >}}
impl Into<NotebookData> for Notebook {
    fn into(self) -> NotebookData {
        NotebookData {
            id: self.id,
            slug: self.slug,
            notes: vec![],
            created_at: self.created_at,
        }
    }
}
{{< / highlight >}}

Now, to implement this functionality. The `Connection::test_connection` method on `diesel` will allow us to easily test this interaction. Running migrations on the created in-memory database takes a little more work, but `migrations_internals` provides functionality that we just run at the beginning of each test. In `src/lib.rs`:

{{< highlight rust "linenos=table,linenostart=50" >}}
#[cfg(test)]
mod tests {
    use super::*;
    use migrations_internals::{run_pending_migrations, setup_database};

    fn setup_test_db(conn: &SqliteConnection) {
        setup_database(conn).expect("Failed to create migrations table");
        run_pending_migrations(conn).expect("Failed to run migrations");
    }

    #[test]
    fn notebook_new_should_return_the_generated_struct() {
        // db::establish_connection will use an in-memory database if no DATABASE_URL environment variable is set, usually by calling `dotenv::dotenv`
        let conn = establish_connection();
        setup_test_db(&conn);

        conn.test_transaction::<_, diesel::result::Error, _>(|| {
            let slug = "some-slug";
            let plaintext_password = "A password, probably!";

            let created = Notebook::new(&conn, slug, plaintext_password).unwrap_or_else(|e| panic!(format!("Notebook::new returned an unexpected error: {}", e)));

            assert_eq!(&created.slug, slug);
            Ok(())
        });
    }
}
{{< / highlight >}}

... and we get our first `not implemented` error:

```
thread 'tests::notebook_new_should_return_the_generated_struct' panicked at 'not yet implemented', src/db/models.rs:18:9
```

Implementing the `db::models::Notebook::create` method is quite simple. In `src/db/models.rs`:

{{< highlight rust "linenos=table,linenostart=7">}}
#[derive(Queryable)]
pub(crate) struct Notebook {
{{< / highlight >}}
{{< highlight rust "linenos=table,linenostart=15" >}}
impl Notebook {
    pub fn create(
        conn: &impl Connection<Backend = Sqlite>,
        slug: &str,
        password_hash: &str,
    ) -> Result<Notebook, Box<dyn std::error::Error>> {
        let notebook_values = NewNotebook { slug, password_hash };
        let _ = diesel::insert_into(notebooks::table)
            .values(&notebook_values)
            .execute(conn)?;
        let created = notebooks::table.filter(notebooks::slug.eq(slug)).limit(1).get_result::<Notebook>(conn)?;
        Ok(created)
    }
}

#[derive(Insertable)]
#[table_name = "notebooks"]
struct NewNotebook<'a> {
    slug: &'a str,
    password_hash: &'a str,
}
{{< / highlight >}}

Due to a limitation of the `sqlite` driver, we can't do a `INSERT INTO...RETURNING` statement, so we need to make two calls. Simple enough, though. Now, the sensitive part of the API — restricting access to correct passwords. In `src/lib.rs`:

{{< highlight rust "linenos=table,linenostart=77" >}}
#[test]
fn notebook_get_by_slug_should_reject_incorrect_passwords() {
    let conn = establish_connection();
    setup_test_db(&conn);

    conn.test_transaction::<_, diesel::result::Error, _>(|| {
        let slug = "some-slug";
        let plaintext_password = "A password, probably!";

        let created = Notebook::new(&conn, slug, plaintext_password).unwrap_or_else(|e| panic!(format!("Unexpected error creating notebook")));

        let fetched = Notebook::get_by_slug(&conn, slug, "The wrong password :(");

        assert_eq!(fetched, Err(NotebookError::NotAuthorized));

        Ok(())
    });
}

#[test]
fn notebook_get_by_slug_should_return_not_found_if_not_exists() {
    let conn = establish_connection();
    setup_test_db(&conn);
    
    conn.test_transaction::<_, diesel::result::Error, _>(|| {
        let fetched = Notebook::get_by_slug(&conn, "not-existing", "Doesn't matter");
        
        assert_eq!(fetched, Err(NotebookError::NotFound));
        
        Ok(())
    });
}
{{< / highlight >}}

Note that we're implicitly using a custom error type, `NotebookError`, to convey the kind of error to the caller. Our tests will error at compile time until we implement them. A few resources on custom error types are [Andrew "burntsushi" Gallant's tutorial](https://blog.burntsushi.net/rust-error-handling/) and the [`failure` crate](https://crates.io/crates/failure), the latter of which we'll be using to implement `std::error::Error` for our type:

{{< highlight rust "linenos=table,linenostart=51" >}}
#[derive(Debug, PartialEq, Fail)]
pub enum NotebookError {
    #[fail(display = "You aren't authorized to view this notebook")]
    NotAuthorized,
    #[fail(display = "Specified notebook was not found")]
    NotFound
}
{{< / highlight >}}

Add the dependency to `Cargo.toml`:

{{< highlight sh >}}
$ echo 'failure = { version = "0.1.3", default-features = false }' >> Cargo.toml
{{< / highlight >}}

> **Note:** I specified `default-features = false` in my `Cargo.toml` entry because I don't need traceback support

Per the compiler, we now need to define and implement `Notebook::get_by_slug`:

