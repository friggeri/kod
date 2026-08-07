interface Point {
    x: number;
    y: number;
}

class Vector implements Point {
    constructor(public x: number, public y: number) {}

    length(): number {
        return Math.sqrt(this.x * this.x + this.y * this.y);
    }
}

const origin: Point = { x: 0, y: 0 };
console.log(new Vector(3, 4).length());
