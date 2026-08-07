//! A tiny, deterministic fixture for `rust-analyzer` integration tests:
//! hover, definition, references, and document symbols are all
//! exercised against this single small file.

pub struct Greeter {
    pub name: String,
}

impl Greeter {
    pub fn new(name: &str) -> Self {
        Greeter { name: name.to_string() }
    }

    /// Returns a friendly greeting for this Greeter's name.
    pub fn greet(&self) -> String {
        format!("Hello, {}!", self.name)
    }
}

pub fn make_default_greeter() -> Greeter {
    Greeter::new("Kod")
}
