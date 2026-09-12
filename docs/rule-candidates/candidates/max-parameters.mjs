const MAX_PARAMETERS = 4;

export default {
  id: "max-parameters",
  category: "complexity",
  layer: "resilience",
  tier: "grit",
  severity: "warn",
  patternKey: "parameter-count",
  title: `a function must not take more than ${MAX_PARAMETERS} parameters`,
  rationale:
    "each parameter is a position the caller must fill in the right order, so a long parameter list makes every call site a puzzle and every reordering a silent bug, it is also the shape that appears when a function has grown to need data from several layers instead of receiving one cohesive value",
  replacement:
    "group the parameters into a named readonly type and pass one object, or split the function until each part needs fewer inputs",
  detect({ ts, sourceFile }) {
    const hits = [];
    const visit = (node) => {
      const hasBody = ts.isFunctionLike(node) && node.body !== undefined;
      if (hasBody && node.parameters.length > MAX_PARAMETERS) {
        const position = sourceFile.getLineAndCharacterOfPosition(
          node.getStart(sourceFile),
        );
        hits.push({
          line: position.line + 1,
          column: position.character + 1,
          snippet: `${node.parameters.length} parameters -- ${node.getText(sourceFile).replace(/\s+/g, " ").slice(0, 90)}`,
        });
      }
      ts.forEachChild(node, visit);
    };
    visit(sourceFile);
    return hits;
  },
};
