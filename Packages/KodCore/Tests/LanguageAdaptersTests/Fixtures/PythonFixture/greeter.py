"""A tiny, deterministic fixture for Pyright integration tests: hover,
definition, references, and document symbols are all exercised against
this single small file."""


class Greeter:
    def __init__(self, name: str) -> None:
        self.name = name

    def greet(self) -> str:
        """Returns a friendly greeting for this Greeter's name."""
        return f"Hello, {self.name}!"


def make_default_greeter() -> Greeter:
    return Greeter("Kod")
