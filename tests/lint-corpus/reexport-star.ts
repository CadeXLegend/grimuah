// the star form re-exports a module the file does not define, which is what the
// ban's message covers, so it reports like the `{ ... }` form
export * from "./a";
