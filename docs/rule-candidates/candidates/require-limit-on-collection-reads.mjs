const findPrepareCall = (ts, node) => {
  let current = node;
  while (current !== undefined) {
    if (ts.isCallExpression(current)) {
      const callee = current.expression;
      if (
        ts.isPropertyAccessExpression(callee) &&
        callee.name.text === "prepare"
      )
        return current;
      current = callee;
      continue;
    }
    if (
      ts.isPropertyAccessExpression(current) ||
      ts.isParenthesizedExpression(current) ||
      ts.isAwaitExpression(current)
    ) {
      current = current.expression;
      continue;
    }
    return undefined;
  }
  return undefined;
};

const sqlTextOf = (ts, sourceFile, prepareCall) => {
  const argument = prepareCall.arguments[0];
  if (argument === undefined) return undefined;
  const isSqlLiteral =
    ts.isStringLiteral(argument) ||
    ts.isTemplateExpression(argument) ||
    ts.isNoSubstitutionTemplateLiteral(argument);
  return isSqlLiteral ? argument.getText(sourceFile) : undefined;
};

export default {
  id: "require-limit-on-collection-reads",
  category: "sql",
  layer: "resilience",
  tier: "grit",
  severity: "warn",
  patternKey: "unbounded-collection-read",
  title: "a query that reads a collection must carry a LIMIT",
  rationale:
    "a prepare chain that ends in all returns every matching row, a where clause bounds the result only by today's data, one prolific account turns a lookup into a full table transfer, and the cost grows silently because the query text never changes when the row count does",
  replacement:
    "add an explicit LIMIT to the select and paginate with an offset or a keyset cursor when the caller genuinely needs everything",
  detect({ ts, sourceFile }) {
    const hits = [];
    const visit = (node) => {
      const isCollectionRead =
        ts.isCallExpression(node) &&
        ts.isPropertyAccessExpression(node.expression) &&
        node.expression.name.text === "all";
      if (isCollectionRead) {
        const prepareCall = findPrepareCall(ts, node);
        const sqlText =
          prepareCall === undefined
            ? undefined
            : sqlTextOf(ts, sourceFile, prepareCall);
        if (
          sqlText !== undefined &&
          /select/i.test(sqlText) &&
          !/\blimit\b/i.test(sqlText)
        ) {
          const position = sourceFile.getLineAndCharacterOfPosition(
            node.getStart(sourceFile),
          );
          hits.push({
            line: position.line + 1,
            column: position.character + 1,
            snippet: sqlText.replace(/\s+/g, " ").slice(0, 120),
          });
        }
      }
      ts.forEachChild(node, visit);
    };
    visit(sourceFile);
    return hits;
  },
};
