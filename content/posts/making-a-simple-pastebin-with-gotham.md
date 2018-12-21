---
title: "Making a Simple Pastebin With Gotham"
date: 2018-12-07T16:57:22+01:00
draft: true
featuredImg: ""
tags: 
  - rust
  - programming
  - gotham
  - web
  - paste
---

## Intro

[Gotham](https://gotham.rs/) recently released `v0.3`, which is the first release by its [new core team](https://gotham.rs/blog/2018/05/31/the-state-of-gotham.html). I feel this is a pretty underrated framework in the Rust ecosystem: [according to the most recent Rust Web Survey](https://rust-lang-nursery.github.io/wg-net/2018/11/28/wg-net-survey.html), Gotham is used by 2.2% of respondents, compared to 27% and 24% for [Rocket](https://rocket.rs/) and [Actix Web](https://actix.rs/), respectively.

The Gotham framework is very simple in that it leverages a lone `State` struct, which is thread through middleware and request handlers:

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

I'm going to write up an exploration of using the Gotham web framework in making a simple paste saving app. For now, we're just going to dump pastes into files which will can be accessed in their raw state. This post assumes a basic understanding of [The Rust Programming Language](https://doc.rust-lang.org/book/second-edition/index.html); although this will not be a 100% line-by-line walkthrough, I'll be explaining my thought process along the way and source for the project (with git tags for each header) is available [here](). I will be using version `1.31.0` and code will be in `Edition 2018`.

## Server check

We're going to start out with a basic `/ping` health check endpoint. This will be a simple test to ensure that our server is up and running. Gotham comes with basic testing functionality baked in, so we can use that in our integration tests:

{{< highlight rust "linenos=table" >}}
use crate::router;
use gotham::test::TestServer;

#[test]
fn health_check_returns_expected() {
    let test_server = TestServer::new(router()).expect("failed to launch test server");

    let response = test_server
        .client()
        .get("http://localhost/ping")
        .perform()
        .expect("failed to get response from `/ping`");

    let body = response.read_body().expect("failed to read response body");

    assert_eq!(&body, b"PONG");
}
{{< / highlight >}}

The new release of `gotham` implements `IntoResponse` for `&'static str`, which means the health check handler is extremely simple:

{{< highlight rust "linenos=table" >}}
use gotham::router::builder::*;
use gotham::router::Router;
use gotham::state::State;

fn ping(state: State) -> (State, &'static str) {
    (state, "PONG")
}

pub fn router() -> Router {
    build_simple_router(|route| {
        route.get_or_head("/ping").to(ping);
    })
}
{{< / highlight >}}

## Templating

We're going to use the `askama` templating engine for our web app. It precompiles Jinja-like templates into Rust structs that can be efficiently rendered. One trick that's easy to miss is using a custom build executable as described in the [readme](https://github.com/djc/askama/blob/0.7.2/README.md):

{{< highlight rust "linenos=table" >}}
fn main() {
    askama::rerun_if_templates_changed();
}
{{< / highlight >}}

The integration test is very similar to the `/ping` endpoint test:

{{< highlight rust "linenos=table" >}}
use gotham::test::TestServer;
use paste::router;

#[test]
fn index_includes_branding() {
    let test_server = TestServer::new(router()).expect("failed to launch test server");

    let response = test_server
        .client()
        .get("http://localhost/")
        .perform()
        .expect("failed to get response from `/`");

    let body = response
        .read_utf8_body()
        .expect("failed to read response body");

    assert!(&body.contains("paste"));
}
{{< / highlight >}}

Our `index.html` is pretty simple:

{{< highlight jinja "linenos=table" >}}
{% extends "base.html" %}

{% block content %}
Hello, Paste!
{% endblock %}
{{< / highlight >}}

It leverages blocks to keep the "landscape" of the site in a `base.html` template:

{{< highlight jinja "linenos=table" >}}
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>paste</title>
</head>
<body>
<header>
    <h1>Paste</h1>
</header>

<div id="content">
    {% block content %}
    {% endblock %}
</div>

</body>
</html>
{{< / highlight >}}

And the handler for `/` simply takes the `Index` template and renders it to a string:

{{< highlight rust "linenos=table,linenostart=8" >}}
#[derive(Debug, Template)]
#[template(path = "index.html")]
struct Index;

fn index(state: State) -> (State, Response<Body>) {
    let tpl = Index {};
    let response = create_response(
        &state,
        StatusCode::OK,
        mime::TEXT_HTML_UTF_8,
        tpl.render().expect("Failed to render index template"),
    );
    (state, response)
}
{{< / highlight >}}

## Adding the form

The index page should show a form, which is simple enough to test. To add a little flexibility (instead of just looking for the entire form element), we'll check for some key elements, such as `form`, `action="/paste"`, etc. as a new unit test in the `index` tests:

{{< highlight rust "linenos=table,linenostart=21" >}}
#[test]
fn index_includes_paste_form() {
    let test_server = TestServer::new(router()).expect("failed to launch test server");

    let response = test_server
        .client()
        .get("http://localhost/")
        .perform()
        .expect("failed to get response from `/`");

    let body = response
        .read_utf8_body()
        .expect("failed to read response body");

    assert!(&body.contains("<form"));
    assert!(&body.contains(r#"action="/paste""#));
    assert!(&body.contains(r#"method="post""#));
    assert!(&body.contains(r#"<textarea name="body""#));
}
{{< / highlight >}}

After making the requisite adjustments to `index.html`, we'll make a new integration test, `web_post_form.rs`:

{{< highlight rust "linenos=table" >}}
use gotham::test::TestServer;
use paste::{router, Paste};

#[test]
fn paste_form_submission_redirects_to_paste_content() {
    let test_server = TestServer::new(router()).expect("failed to launch test server");

    let paste_body = "print('Hello, World!')";

    let data = Paste {
        body: paste_body.to_string()
    };

    let serialized = serde_urlencoded::to_string(&data).expect("Failed to serialize form");

    let response = test_server
        .client()
        .post("http://localhost/paste", serialized.into_bytes(), mime::APPLICATION_WWW_FORM_URLENCODED)
        .perform()
        .expect("failed to get response from `/`");

    let body = response
        .read_utf8_body()
        .expect("failed to read response body");

    assert_eq!(&body, paste_body);
}
{{< / highlight >}}

The `Paste` struct will be the form input we'll deserialize from the request (and serialize, in this test):

{{< highlight rust "linenos=table" >}}
use serde_derive::{Serialize, Deserialize};

#[derive(Serialize, Deserialize)]
pub struct Paste {
    body: String,
}
{{< / highlight >}}

Our `/paste` handler will decode the form input, generate a (generally) unique file name, and write the paste to a text file with that name. But before we can implement this full-circle test, we need to implement the display of raw pastes.

## Displaying pastes

We'll write a separate integration test suite for raw paste serving:

{{< highlight rust "linenos=table" >}}
use gotham::test::TestServer;
use paste::router;
use paste::Paste;
use paste::PASTE_DIRECTORY;
use std::fs;
use std::path::Path;
use std::path::PathBuf;

#[test]
fn raw_paste_returns_existing_paste_value() {
    let paste_body = "print('Hello, World!')";

    let paste_path = PathBuf::new().join(PASTE_DIRECTORY).join("test");
    fs::write(&paste_path, paste_body).expect("Failed to write test file");

    let test_server = TestServer::new(router()).expect("failed to launch test server");

    let response = test_server
        .client()
        .get("http://localhost/raw/test")
        .perform()
        .expect("failed to get response from `/raw/test`");

    let body = response
        .read_utf8_body()
        .expect("failed to read response body");

    fs::remove_file(&paste_path).expect("Failed to delete test file");

    assert_eq!(&body, paste_body);
}
{{< / highlight >}}

Gotham added a new static file serving feature that will prove useful for this:

{{< highlight rust "linenos=table,linenostart=40">}}
        route.get_or_head("/raw/*").to_dir(
            FileOptions::new(PASTE_DIRECTORY)
                .with_brotli(true)
                .with_gzip(true)
                .build()
        );
{{< / highlight >}}

## Saving form input

Now we can implement the form handler. We use `serde` to decode the body, and then use `fs::write` to save the file efficiently:

