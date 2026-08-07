"""A sample module."""
import math


class Circle:
    """A circle with a radius."""

    def __init__(self, radius):
        self.radius = radius

    def area(self):
        return math.pi * self.radius ** 2


circle = Circle(2.0)
print(circle.area())
