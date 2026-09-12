export default {
  id: "no-boolean-flag-argument",
  category: "patterns",
  layer: "resilience",
  tier: "grit",
  severity: "warn",
  patternKey: "boolean-flag-argument",
  title: "a call must not pass a bare boolean literal as an argument",
  rationale:
    "a boolean argument makes one function do two jobs and hides which job the call site asked for, true and false read identically at the call, so the reader has to open the callee to learn what the position means, and every new variant adds another positional flag that only the callee can decode",
  replacement:
    "give the two behaviours their own named functions, or pass a named enum or union value so the call site says what it wants, and keep a boolean parameter only when the callee is a third-party api whose signature you do not control",
  detect({ ts, sourceFile }) {
    const hits = [];
    const visit = (node) => {
      if (ts.isCallExpression(node)) {
        for (const argument of node.arguments) {
          const isBooleanLiteral =
            argument.kind === ts.SyntaxKind.TrueKeyword ||
            argument.kind === ts.SyntaxKind.FalseKeyword;
          if (isBooleanLiteral) {
            const position = sourceFile.getLineAndCharacterOfPosition(
              argument.getStart(sourceFile),
            );
            hits.push({
              line: position.line + 1,
              column: position.character + 1,
              snippet: `${node.expression.getText(sourceFile).replace(/\s+/g, " ").slice(0, 70)}(${argument.getText(sourceFile)})`,
            });
          }
        }
      }
      ts.forEachChild(node, visit);
    };
    visit(sourceFile);
    return hits;
  },
};
