// A sample comment.
function fibonacci(n) {
    if (n <= 1) {
        return n;
    }
    return fibonacci(n - 1) + fibonacci(n - 2);
}

const values = [0, 1, 2, 3, 4].map(fibonacci);
console.log(values);
