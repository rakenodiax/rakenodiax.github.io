---
title: "Making a Pastebin With Gotham"
date: 2018-12-05T13:09:42+01:00
draft: true
featuredImg: ""
tags: 
  - rust
  - gotham
  - walkthrough
categories:
    - programming
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

I'm going to write up an exploration of using the Gotham web framework in making a simple paste saving app. Each paste will be given a unique URL, with more features to be added later. This post assumes a basic understanding of [The Rust Programming Language](https://doc.rust-lang.org/book/second-edition/index.html), but I'll be explaining my thought process along the way. I will be using version `1.31.0` and code will be in `Edition 2018`.

## Crate and dependencies

To do integration testing on our web app, we're going to use `gotham`'s built in testing capability. Our initial `Cargo.toml` will look like this:

{{< highlight toml "linenos=table" >}}
[package]
name = "pasters"
version = "0.1.0"
authors = ["Your Info Here"]
edition = "2018"

[dependencies]
gotham = "0.3.0"
hyper = "0.12.16"
mime = "0.3.12"
{{< / highlight >}}

## Our first integration test

The first integration test will just ensure we have a working web server which mentions some key words in the response. In `tests/index_html.rs`:

{{< highlight rust "linenos=table" >}}
use gotham::test::TestServer;
use hyper::StatusCode;
use pasters::router;

#[test]
fn index_response_should_include_branding() {
    let test_server = TestServer::new(router())
        .expect("Failed to mount the root router");

    let response = test_server
        .client()
        .get("http://localhost")
        .perform()
        .expect("Failed to get response from test server");

    assert_eq!(response.status(), StatusCode::OK);

    let raw_body = response.read_body()
        .expect("Response did not contain body");
    let response_content = String::from_utf8(raw_body)
        .expect("Response body was not valid UTF-8");

    assert!(&response_content.contains("paste.rs"));
}
{{< / highlight >}}

The example router from the `gotham` example directory will help the first assertion pass, and now we just need to render the apropriate content:

{{< highlight rust "linenos=table" >}}
use gotham::router::builder::{build_simple_router, DefineSingleRoute, DrawRoutes};
use gotham::router::Router;
use gotham::state::State;

fn index(state: State) -> (State, &'static str) {
    (state, "Hello, world!")
}

pub fn router() -> Router {
    build_simple_router(|route| {
        route.get_or_head("/").to(index);
    })
}
{{< / highlight >}}

## Rendering HTML

We're going to render HTML using the [`askama` templating library](https://crates.io/crates/askama). Its syntax is similar to `Jinja2`, but template structs are compiled down into very efficient data structures, instead of loading the template each time it is rendered. Add the following to `src/lib.rs`:

{{< highlight rust "linenos=table,linenostart=4" >}}
use askama::Template;

#[derive(Debug, Template)]
#[template(path = "index.html")]
struct Index;
{{< / highlight >}}

There is some setup that's needed to make `askama` work smoothly. As templates are compiled into the application, we need to use a custom `build.rs` in our crate root with the following contents:

```rust
main() {
    askama::rerun_if_templates_changed();
}
```

...`askama` should be added to both `[dependencies]` and `[dev-dependencies]` in `Cargo.toml`:

{{< highlight toml "linenos=table,linenostart=12" >}}
askama = "0.7.2"

[build-dependencies]
askama = "0.7.2"
{{< / highlight >}}

...`askama` will use `$CRATE_ROOT/templates` as its default directory, which is fine for this app. The following `index.html` will be sufficient for our test:

{{< highlight html "linenos=table" >}}
<!DOCTYPE html>
<html>
    <head>
        <title>paste.rs</title>
    </head>
    <body>
        <header>
            <h1>paste.rs</h1>
            <h2>Paste and share</h2>
        </header>
    </body>
</html>
{{< / highlight >}}

Now we can use the `Template::render` method to render our template and return it from our handler:

{{< highlight rust "linenos=table,linenostart=6,hl_lines=10-12" >}}
use hyper::Body;
use hyper::Response;
use hyper::StatusCode;

#[derive(Debug, Template)]
#[template(path = "index.html")]
struct Index;

fn index(state: State) -> (State, Response<Body>) {
    let tpl = Index {};
    let rendered = tpl.render().expect("Failed to render `index` template");
    let res = create_response(&state, StatusCode::OK, mime::TEXT_HTML_UTF_8, rendered);
    (state, res)
}
{{< / highlight >}}

Now that the first test passes, let's create another one to ensure that our homepage includes a form to submit new pastes:

{{< highlight rust "linenos=table,linenostart=26" >}}
#[test]
fn index_response_should_include_paste_form() {
    let expected_form_text =  r#"<form action="/paste" method="post">
                <input type="text" name="title" placeholder="optional title">
                <input type="textarea" name="body" placeholder="your paste here" required>
                <button type="submit" value="Save">
            </form>"#;

    let test_server = TestServer::new(router())
        .expect("Failed to mount the root router");

    let response = test_server
        .client()
        .get("http://localhost")
        .perform()
        .expect("Failed to get response from test server");

    let raw_body = response.read_body()
        .expect("Response did not contain body");
    let response_content = String::from_utf8(raw_body)
        .expect("Response body was not valid UTF-8");

    assert!(&response_content.contains(expected_form_text));
}
{{< / highlight >}}

> **Note:** Be mindful of the whitespace in `expected_form_text`; it must match what you add to `index.html` exactly.

Now we update `templates/index.html`:

{{< highlight html "linenos=table,linenostart=6,hl_lines=6-12" >}}
    <body>
        <header>
            <h1>paste.rs</h1>
            <h2>Paste and share</h2>
        </header>
        <div id="content">
            <form action="/paste" method="post">
                <input type="text" name="title" placeholder="optional title">
                <input type="textarea" name="body" placeholder="your paste here" required>
                <button type="submit" value="Save">
            </form>
        </div>
    </body>
{{< / highlight >}}

## Testing form input

Now we test what happens when we submit the form on the home page. Create a separate integration test in `tests/paste_form.rs`:

{{< highlight rust "linenos=table" >}}
use pasters::router;
use pasters::web::forms;
use gotham::test::TestServer;
use hyper::StatusCode;

#[test]
fn paste_response_should_include_pasted_text() {
    let paste_body = "print('Hello, world!)'";

    let form = forms::Paste {
        title: None,
        body: paste_body.to_string(),
    };

    let test_server = TestServer::new(router())
        .expect("Failed to mount the root router");

    let response = test_server
        .client()
        .post("/paste", serde_urlencoded::to_string(&form).expect("failed to encode forms::Paste"), mime::APPLICATION_WWW_FORM_URLENCODED)
        .perform()
        .expect("Failed to send form to '/paste'");

    assert_eq!(response.status(), StatusCode::CREATED);

    let raw_body = response.read_body()
        .expect("Response did not contain body");
    let response_content = String::from_utf8(raw_body)
        .expect("Response body was not valid UTF-8");

    assert!(&response_content.contains(paste_body));
}
{{< / highlight >}}

This will throw up a lot of errors. To dispatch with the simple ones first:
- add `serde_urlencoded = "0.5.4"` as a dependency to `Cargo.toml`
- move `src/lib.rs` to `src/web.rs`
- create a new `src/lib.rs` containing `pub mod web;` and `pub use crate::web::router;`
- create an empty `src/web/forms.rs` file

Finally, let's create the form struct in `src/web/forms.rs`:

{{< highlight rust "linenos=table" >}}
pub struct Paste {
    pub title: Option<String>,
    pub body: String,
}
{{< / highlight >}}

Now the compiler is telling us to implement `serde::Serialize` for `forms::Paste`. Derive `Serialize` for the struct:

{{< highlight rust "linenos=table" >}}
use serde_derive::Serialize;

#[derive(Debug, PartialEq, Serialize)]
pub struct Paste { ... }
{{< / highlight >}}

...and add the requisite dependencies to `Cargo.toml`:

{{< highlight toml "linenos=table,linenostart=14" >}}
serde = "1.0.80"
serde_derive = "1.0.80"
{{< / highlight >}}

## Set up the database

We know that our database will be a dependency for persisting data, and `diesel` is the most popular way to interface with databases from Rust. If you aren't familiar with the library, check out their comprehensive [getting started guide](https://diesel.rs/guides/getting-started/). We'll be using `postgres`, so ensure that you've created the appropriate user and database, as well. Once `diesel` has been set up for the project, create our `paste` table migration:

```sh
$ diesel migration generate create_pastes
```

... with the following `up.sql`:

{{< highlight postgres "linenos=table" >}}
CREATE TABLE pastes (
    id SERIAL PRIMARY KEY,
    title TEXT,
    body TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

SELECT diesel_manage_updated_at('pastes');
{{< / highlight >}}

This creates a table with the same fields in our data struct, and leverages the built in `diesel_manage_updated_at` function to handle our timestamps for us. Don't forget the corresponding `down.sql` migration:

{{< highlight postgres "linenos=table" >}}
DROP TABLE pastes;
{{< / highlight >}}

We're going to keep our database logic in a top-level `db` module; create that directory and modify the `diesel.toml` configuration to print the schema macros to that directory:

{{< highlight toml "linenos=table,hl_lines=2" >}}
[print_schema]
file = "src/db/schema.rs"
{{< / highlight >}}

Diesel does not support the new style of macro importing. Add the following to the beginning of `src/lib.rs` to import all of `diesel`'s macros into your app:
{{< highlight rust "linenos=table" >}}
#[macro_use]
extern crate diesel;
{{< / highlight >}}

> **Note:** To suppress the deprectation warnings from Diesel's macros, add the following to be beginning to `src/lib.rs`:

{{< highlight rust "linenos=table" >}}
#![allow(proc_macro_derive_resolution_fallback)]
{{< / highlight >}}

## Representing paste data

Now our tests tell us that we can finally work on implementing our `/paste` endpoint. The first step is to outline what a paste data should look like. Let's create a `data.rs` module, with the following `struct`:

{{< highlight rust "linenos=table" >}}
use chrono::prelude::*;
use serde_derive::Serialize;

#[derive(Debug, PartialEq, Serialize)]
pub struct Paste {
    id: i32,
    title: Option<String>,
    body: String,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}
{{< / highlight >}}

Make sure to include the `serde` feature when specifying the `chrono` dependency.

Now we will write a method on `data::Paste` to create a new paste and save it to the database:

{{< highlight rust "linenos=table,linenostart=13" >}}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::establish_connection;
    use dotenv::dotenv;
    use diesel::Connection;

    #[test]
    fn paste_create_returns_created_paste() {
        dotenv().ok();

        let conn = establish_connection();

        conn.test_transaction::<_, diesel::result::Error, _>(|| {
            let body = "some paste";
            let title = "a title";

            let created_with_title = Paste::save(&conn, Some(title), body).expect("Failed to save a paste with title");
            let created_without_title = Paste::save(&conn, None, body).expect("Failed to save a paste without a title");

            assert_eq!(created_with_title.title.unwrap().as_str(), title);
            assert_eq!(&created_with_title.body, body);

            assert!(created_without_title.title.is_none());
            assert_eq!(&created_without_title.body, body);

            Ok(())
        });
    }
}
{{< / highlight >}}

An option for implementing the `save` method would be to use the `db::schema` module directly. However, `diesel` offers macros for representing database rows as Rust structs, which are easier to work with, and allow for a clean separation of concerns between business logic and data, and persisted storage. With that in mind, let's implement `save` as:

{{< highlight rust "linenos=table,linenostart=16">}}
impl Paste {
    pub fn save<'a>(
        conn: &impl Connection<Backend = Pg>,
        title: impl Into<Option<&'a str>>,
        body: impl AsRef<str>,
    ) -> Result<Paste, diesel::result::Error> {
        let created = models::Paste::create(conn, title.into(), body.as_ref())?;
        Ok(created.into())
    }
}
{{< / highlight >}}

...and now we create a test in `src/db/models.rs` for the `Paste::create` method, which will look very similar to the one we made in `src/data.rs`:

{{< highlight rust "linenos=table" >}}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::establish_connection;
    use diesel::prelude::*;
    use dotenv::dotenv;

    #[test]
    fn paste_create_saves_data_to_database() {
        dotenv().ok();

        let conn = establish_connection();

        conn.test_transaction::<_, diesel::result::Error, _>(|| {
            let body = "some paste";
            let title = "a title";

            let created_with_title =
                Paste::create(&conn, Some(title), body).expect("Failed to save a paste with title");
            let created_without_title =
                Paste::create(&conn, None, body).expect("Failed to save a paste without a title");

            assert_eq!(created_with_title.title.unwrap().as_str(), title);
            assert_eq!(&created_with_title.body, body);

            assert!(created_without_title.title.is_none());
            assert_eq!(&created_without_title.body, body);

            Ok(())
        });
    }
}
{{< / highlight >}}

We create the struct and method:

{{< highlight rust "linenos=table" >}}
use chrono::prelude::*;
use diesel::pg::Pg;
use diesel::prelude::*;

pub struct Paste {
    pub id: i32,
    pub title: Option<String>,
    pub body: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl Paste {
    pub fn create(
        conn: &impl Connection<Backend = Pg>,
        title: Option<&str>,
        body: &str,
    ) -> Result<Paste, diesel::result::Error> {
        unimplemented!();
    }
}
{{< / highlight >}}

Now we allow `models::Paste` to convert into `data::Paste`:

{{< highlight rust "linenos=table,linenostart=27" >}}
impl From<models::Paste> for Paste {
    fn from(model: models::Paste) -> Paste {
        Paste {
            id: model.id,
            title: model.title,
            body: model.body,
            created_at: model.created_at,
            updated_at: model.updated_at
        }
    }
}
{{< / highlight >}}

Finally, we implement `models::Paste::save` to resove the `not_yet_implemented` errors:

{{< highlight rust "linenos=table,linenostart=15" >}}
impl Paste {
    pub fn create(
        conn: &impl Connection<Backend = Pg>,
        title: Option<&str>,
        body: &str,
    ) -> Result<Paste, diesel::result::Error> {
        let new_paste = NewPaste {
            title, body
        };

        diesel::insert_into(pastes::table)
            .values(&new_paste)
            .get_result(conn)
    }
}
{{< / highlight >}}

The method body is incredibly sparse. This is due to two macros from `diesel`: `Insertable` and `Queryable`, which allow easy conversion from structs to either insertable or queryable values. We use a private struct for the insertable `NewPaste` data:

{{< highlight rust "linenos=table,linenostart=31">}}
#[derive(Debug, Insertable)]
#[table_name = "pastes"]
struct NewPaste<'a> {
    title: Option<&'a str>,
    body: &'a str,
}
{{< / highlight >}}

## Handling the paste request

Now that our data ducks are in a row, we can implement the glue connecting a `/paste` request through data saving and back through to the response to the user. We'll start with a handler:

{{< highlight rust "linenos=table" >}}
{{< / highlight >}}