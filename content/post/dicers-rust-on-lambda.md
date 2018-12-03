---
title: "Dice.rs: Rust on Lambda"
date: 2018-12-02T14:18:59+01:00
tags: rust, aws, lambda
draft: false
---

Rust support on AWS Lambda [was recently released](https://github.com/awslabs/aws-lambda-rust-runtime), which seems like as good an opportunity as any to share some code and the solutions to challenges I encountered along the way ☺. I've decided to create a little diceware service, and the `lambda-runtime` crate provides a great API to make this a breeze.

## Setting up the library

We're going to generate a basic crate:

```
$ cargo new dicers --lib && cd dicers
     Created library `dicers` project
```

You should see a structure similar to this:

```
$ ls -a
./		.git/		Cargo.toml
../		.gitignore	src/
```

## Write the core data structure

I'm going to expose the phrase generator as a dictionary which implements an `Iterator`, from which the user can `take` however many words needed for the phrase. Iterators also provide a nice way to seed and add to the dictionary. The Rust standard library includes traits for both of these features: `FromIterator` and `Extend`; we'll write two quick tests to describe this behavior:

{{< highlight rust "linenos=table" >}}
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dictionary_implements_from_iterator() {
        let seed = || vec!["foo".to_string(), "bar".to_string()].into_iter();

        let dictionary = Dictionary::from_iter(seed());

        assert_eq!(dictionary.words, HashSet::from_iter(seed()));
    }

    #[test]
    fn dictionary_implements_extend() {
        let addition = || vec!["foo".to_string(), "bar".to_string()].into_iter();

        let mut dictionary = Dictionary::default();

        dictionary.extend(addition());

        assert_eq!(
            dictionary.words,
            HashSet::from_iter(addition().map(|s| s.to_string()))
        );
    }
}
{{< / highlight >}}

`cargo test` prompts us to create a `Dictionary` struct and import `HashSet`. We can derive some basic traits for `Dictionary` while we're at it:

{{< highlight rust "linenos=table" >}}
use std::collections::HashSet;

#[derive(Debug, Default, Clone, PartialEq)]
pub struct Dictionary {
    words: HashSet<String>
}
{{< / highlight >}}

Now `cargo test` leads us to import the appropriate traits so they can be used:

{{< highlight rust "linenos=table,hl_lines=2" >}}
use std::collections::HashSet;
use std::iter::{Extend, FromIterator};
{{< / highlight >}}

Implementing `Extend` and `FromIterator` is incredibly easy, as the underlying `HashSet` implements them:

{{< highlight rust "linenos=table,linenostart=9" >}}
impl<S> FromIterator<S> for Dictionary
where
    S: ToString,
{
    fn from_iter<I: IntoIterator<Item = S>>(iter: I) -> Dictionary {
        let words = HashSet::from_iter(iter.into_iter().map(|s| s.to_string()));

        Dictionary { words }
    }
}

impl<S> Extend<S> for Dictionary
where
    S: ToString,
{
    fn extend<I: IntoIterator<Item = S>>(&mut self, iter: I) {
        self.words.extend(iter.into_iter().map(|s| s.to_string()));
    }
}
{{< / highlight >}}

And now the tests pass, yay!

```
running 2 tests
test tests::dictionary_implements_from_iterator ... ok
test tests::dictionary_implements_extend ... ok

test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out
```

## Iterating over generated words

Now we'll implement `Iterator` for `Dictionary`. This iterator will return a random word each time `next` is called. First things first, we'll write a test that exercises this behavior:

{{< highlight rust "linenos=table,linenostart=56" >}}
#[test]
fn dictionary_can_be_iterated_over() {
    let word = "foo";

    let dictionary = Dictionary::from_iter(vec![word].into_iter());

    let generated = dictionary.iter().next();

    assert_eq!(generated, Some(word));
}
{{< / highlight >}}

Each time the dictionary is iterated over, a separate RNG will be instantiated. A `DictionaryIterator` struct contains a borrow of the `Dictionary.words`, and the RNG:

{{< highlight rust "linenos=table" >}}
use rand::prelude::*;
{{< / highlight >}}
{{< highlight rust "linenos=table,linenostart=30">}}
impl Dictionary {
    pub fn iter(&self) -> DictionaryIterator {
        DictionaryIterator::new(&self.words)
    }
}

pub struct DictionaryIterator<'a> {
    words: &'a HashSet<String>,
    rng: ThreadRng,
}

impl<'a> DictionaryIterator<'a> {
    fn new(words: &'a HashSet<String>) -> DictionaryIterator<'a> {
        let rng = thread_rng();

        DictionaryIterator { words, rng }
    }
}

impl<'a> Iterator for DictionaryIterator<'a> {
    type Item = &'a str;

    fn next(&mut self) -> Option<Self::Item> {
        let word_count = self.words.len();
        let index = self.rng.gen_range(0, word_count);

        self.words.iter().skip(index).next().map(|s| s.as_str())
    }
}
{{< / highlight >}}

Don't forget to add `rand` as a dependency to `Cargo.toml`:

{{< highlight toml "linenos=table,linenostart=7">}}
[dependencies]
rand = "0.6.1"
{{< / highlight >}}

Using an iterator allows the use of `take` to generate arbitrary numbers of words:

{{< highlight rust >}}
let four = dictionary.iter().take(4);
{{< / highlight >}}

## Populating the dictionary

In actual use, the `Dictionary` needs to be seeded with a given set of words. We'll store this in a text file, with each line being a word in the dictionary, and add support to read any string in this format and create a `Dictionary` from it:

{{< highlight rust "linenos=table,linenostart=13" >}}
impl Dictionary {
    pub fn read_str(input: &str) -> Dictionary {
        // `String.lines` implements `Iterator`, so we can use it directly with `FromIterator`
        Dictionary::from_iter(input.lines())
    }
}
{{< / highlight >}}

## Building against AWS Lambda

The `lambda-runtime` crate is pretty simple to use. We define a handler function which takes a `serde` deserializable struct and context, returning either a `serde` serializable struct or an error. Let's start by adding the necessary dependencies to `Cargo.toml`:

{{< highlight toml "linenos=table,linenostart=9" >}}
lambda_runtime = "0.1.0"
serde_derive = "1.0.80"
{{< / highlight >}}

We'll implement the API in a separate module: create `src/api.rs` and declare the module in `src/lib.rs`:

{{< highlight rust "linenos=table,linenostart=5" >}}
mod api;
pub use self::api::handler;
{{< / highlight >}}

We'll start with the request and response structs, in `src/api.rs`:

{{< highlight rust "linenos=table" >}}
use serde_derive::{Deserialize, Serialize};

#[derive(Debug, Deserialize)]
pub struct GenerateEvent {
    word_count: u8,
    separator: char,
}

#[derive(Debug, Serialize)]
pub struct GenerateResponse {
    phrase: String,
}
{{< / highlight >}}

The business logic is simple enough that we can just implement it directly in the handler function used by Lambda.

{{< highlight rust "linenos=table" >}}
use super::Dictionary;
{{< / highlight >}}
{{< highlight rust "linenos=table,linenostart=17" >}}
pub fn handler(event: GenerateEvent, _ctx: Context) -> Result<GenerateResponse, HandlerError> {
    match event {
        GenerateEvent {
            word_count,
            separator: Some(separator),
        } => {
            let seed = include_str!("../resources/dictionary.txt");
            let dictionary = Dictionary::read_str(&seed);
            let words: Vec<&str> = dictionary.iter().take(word_count as usize).collect();
            let phrase = words.as_slice().join(&separator.to_string());
            Ok(GenerateResponse { phrase })
        }

        GenerateEvent {
            word_count,
            separator: None,
        } => {
            let seed = include_str!("../resources/dictionary.txt");
            let dictionary = Dictionary::read_str(&seed);

            // Iterators of type `&str` can be joined into one `String` with `collect`
            let phrase: String = dictionary.iter().take(word_count as usize).collect();
            Ok(GenerateResponse { phrase })
        }
    }
}
{{< / highlight >}}

This implementation can definitely be cleaned up; there's the repeated logic of reading the dictionary file, along with `unwrap`, which means that the function *could* panic at runtime. We can clean this up by using the `lazy_static` crate:

{{< highlight rust "linenos=table,linenostart=3,hl_lines=1 4-7" >}}
use lazy_static::lazy_static;
use serde_derive::{Deserialize, Serialize};

lazy_static! {
    static ref DICTIONARY: Dictionary = {
        let seed = include_str!("../resources/dictionary.txt");
        Dictionary::read_str(&seed)
    }
}
{{< / highlight >}}

The dictionary will now be instantiated the first time it's used. Let's use the dictionary in our handler:

{{< highlight rust "linenos=table,linenostart=22,hl_lines=7 17" >}}
pub fn handler(event: GenerateEvent, _ctx: Context) -> Result<GenerateResponse, HandlerError> {
    match event {
        GenerateEvent {
            word_count,
            separator: Some(separator),
        } => {
            let words: Vec<&str> = DICTIONARY.iter().take(word_count as usize).collect();
            let phrase = words.as_slice().join(&separator.to_string());
            Ok(GenerateResponse { phrase })
        }

        GenerateEvent {
            word_count,
            separator: None,
        } => {
            // Iterators of type `&str` can be joined into one `String` with `collect`
            let phrase: String = DICTIONARY.iter().take(word_count as usize).collect();
            Ok(GenerateResponse { phrase })
        }
    }
}
{{< / highlight >}}

## Write a main function

The `lambda_runtime` crate provides a macro for exposing a handler function to Lambda. The complete `main.rs` file:

{{< highlight rust "linenos=table" >}}
use dicers::handler;
use lambda_runtime::lambda;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    lambda!(handler);

    Ok(())
}
{{< / highlight >}}

## Deploy to AWS Lambda

The crate must be built for the `x86_64-unknown-linux-musl` target. If you are MacOS, the following steps will allow for cross compilation:

{{< highlight sh >}}
# Add the target via rustup
$ rustup target add x86_64-unknown-linux-musl
# install the homebrew cross-compilation binaries
$ brew install filosottile/musl-cross/musl-cross
# cargo can't find the default binary name, so we use a symlink to the one it is expecting
$ ln -s /usr/local/bin/x86_64-linux-musl-gcc /usr/local/bin/musl-gcc
{{< / highlight >}}

And add the following configuration file, located at `.cargo/config`:

{{< highlight toml "linenos=table" >}}
[build]
target = "x86_64-unknown-linux-musl"

[target.x86_64-unknown-linux-musl]
linker = "x86_64-linux-musl-gcc"
{{< / highlight >}}

This will tell `cargo` to build for the appropriate target, and use the linker we just installed. Now we can build and publish the Lambda function using the [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-welcome.html):

{{< highlight sh >}}
# Build with optimizations
$ cargo build --release
# Copy the binary as a bootstrap file
$ cp ./target/x86_64-unknown-linux-musl/release/dicers ./bootstrap
# Compress into a lambda archive and remove the intermediary bootstrap file
$ zip lambda.zip bootstrap && rm bootstrap
# Replace the `role` argument with the Role ARN from the AWS IAM console. The user must be granted the `lambda:CreateFunction` permission and the role allowed `XRay:PutTraceSegments`:
$ aws lambda create-function --function-name dicers \
--handler doesnt.matter \
--zip-file fileb://./lambda.zip \
--runtime provided \
--role arn:aws:iam::XXXXXXXXXXX:role/my-role \
--environment Variables={RUST_BACKTRACE=1} \
--tracing-config Mode=Active
{{< / highlight >}}

And now we can use a test invocation to ensure it's up and running:

{{< highlight sh >}}
$ aws lambda invoke --function-name dicers \
--payload '{"word_count": 5, "separator":"-"}' \
output.json
{
    "StatusCode": 200,
    "ExecutedVersion": "$LATEST"
}
$ cat output.json
{"phrase":"heading-reimburse-preformed-pledge-appliance"}
{{< / highlight >}}

And that should be it! I'd love to get feedback on this post, either by [GitLab Issue](https://gitlab.com/rakenodiax/rakenodiax.gitlab.io/issues/new) or [Twitter](https://twitter.com/rakenodiax)