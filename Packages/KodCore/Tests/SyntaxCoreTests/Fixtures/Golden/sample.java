class Greeter {
    private final String name;

    Greeter(String name) {
        this.name = name;
    }

    String greet() {
        return "Hello, " + name;
    }
}
