// a Map keeps the lookup free of inherited Object.prototype members, a plain
// object literal would answer toString and toLocaleString with a real function
const MUTATING_METHODS = new Map([
  ["sort", "toSorted"],
  ["reverse", "toReversed"],
  ["splice", "toSpliced"],
]);

const COPY_PRODUCERS = new Set([
  "slice",
  "toSorted",
  "toReversed",
  "toSpliced",
  "filter",
  "map",
  "concat",
  "flat",
  "flatMap",
]);

export default {
  id: "no-mutating-array-methods",
  category: "declarative",
  layer: "resilience",
  tier: "grit",
  severity: "error",
  patternKey: "mutating-array-methods",
  title: "sort, reverse and splice must not mutate a shared array",
  rationale:
    "sort, reverse and splice edit the receiver in place, so a caller that hands an array to a helper can have its own copy reordered without any assignment, the mutation travels through aliases and the defect surfaces far from the call, the copy-on-write variants return a new array and leave the input untouched",
  replacement:
    "use the copying variants toSorted, toReversed and toSpliced, or spread or slice the input first when the copy is needed explicitly",
  detect({ ts, sourceFile }) {
    const hits = [];
    const isFreshReceiver = (receiver) => {
      if (ts.isArrayLiteralExpression(receiver)) return true;
      if (!ts.isCallExpression(receiver)) return false;
      if (!ts.isPropertyAccessExpression(receiver.expression)) return false;
      return COPY_PRODUCERS.has(receiver.expression.name.text);
    };
    const visit = (node) => {
      if (
        ts.isCallExpression(node) &&
        ts.isPropertyAccessExpression(node.expression)
      ) {
        const replacement = MUTATING_METHODS.get(node.expression.name.text);
        if (
          replacement !== undefined &&
          !isFreshReceiver(node.expression.expression)
        ) {
          const position = sourceFile.getLineAndCharacterOfPosition(
            node.getStart(sourceFile),
          );
          hits.push({
            line: position.line + 1,
            column: position.character + 1,
            snippet: `${node.getText(sourceFile).replace(/\s+/g, " ").slice(0, 100)} -- use ${replacement}`,
          });
        }
      }
      ts.forEachChild(node, visit);
    };
    visit(sourceFile);
    return hits;
  },
};
