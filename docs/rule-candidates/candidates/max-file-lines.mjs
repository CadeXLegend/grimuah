const MAX_FILE_LINES = 500;

export default {
  id: "max-file-lines",
  category: "complexity",
  layer: "resilience",
  tier: "grit",
  severity: "warn",
  patternKey: "file-length",
  title: `a module must not exceed ${MAX_FILE_LINES} lines`,
  rationale:
    "a module past the cap has almost always grown a second responsibility because the first one no longer fits the file's name, every reader pays the whole file's cost to find one function, and the file becomes the place changes are made by default rather than the place one concern is expressed",
  replacement:
    "split the module along the responsibilities already visible in its section comments, giving each extracted part a name that says what it does and an import edge that shows who needs it",
  detect({ ts, sourceFile, relPath }) {
    if (relPath.endsWith(".d.ts")) return [];
    const lineCount =
      sourceFile.getLineAndCharacterOfPosition(sourceFile.end).line + 1;
    if (lineCount <= MAX_FILE_LINES) return [];
    return [
      {
        line: 1,
        column: 1,
        snippet: `${lineCount} lines in ${relPath}, over the ${MAX_FILE_LINES} line cap`,
      },
    ];
  },
};
