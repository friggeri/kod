// A tiny, deterministic fixture for `typescript-language-server`
// integration tests: hover, definition, references, and document
// symbols are all exercised against this single small file.
export class Greeter {
    constructor(public name: string) {}

    /** Returns a friendly greeting for this Greeter's name. */
    greet(): string {
        return `Hello, ${this.name}!`;
    }
}

export function makeDefaultGreeter(): Greeter {
    return new Greeter("Kod");
}
