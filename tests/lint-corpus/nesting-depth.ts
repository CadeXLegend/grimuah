// a body past the nesting limit: the `if` on line 5 sits four layers in, and the
// `for` on line 6 sits five
export function deep(xs: number[]): void {
  for (const x of xs) {
    if (x > 0) {
      while (x > 1) {
        if (x > 2) {
          for (const y of xs) {
            void y;
          }
        }
      }
    }
  }
}

// the same shape one layer shallower, and a nested function whose body starts
// its own count at zero
export function shallow(xs: number[]): void {
  for (const x of xs) {
    if (x > 0) {
      while (x > 1) {
        void x;
      }
    }
  }
}
