// an async operation whose declared result is a bare scalar cannot say why it
// failed. false and 1 and 0 are all valid business values, so a caller cannot
// tell "the answer is no" from "the read broke", and the reason the operation
// already knows is thrown away at the boundary that had it
const SCALAR_RETURN_TYPES = new Set(["boolean", "number"]);

const isExported = (ts, node) =>
  node.modifiers?.some(
    (modifier) => modifier.kind === ts.SyntaxKind.ExportKeyword,
  ) === true;

const isAsync = (ts, node) =>
  node.modifiers?.some(
    (modifier) => modifier.kind === ts.SyntaxKind.AsyncKeyword,
  ) === true;

// the settled value of a Promise<T> annotation, or nothing for any other shape
const settledTypeOf = (ts, annotation) => {
  if (annotation === undefined || !ts.isTypeReferenceNode(annotation))
    return undefined;
  if (annotation.typeName.getText() !== "Promise") return undefined;
  const [settled] = annotation.typeArguments ?? [];
  return settled;
};

const describe = (ts, name, annotation, settled) =>
  `${name}(): ${annotation.getText()} settles to ${settled.getText()}`;

export default {
  id: "no-async-scalar-failure-return",
  category: "resilience",
  layer: "resilience",
  tier: "prepass",
  severity: "warn",
  patternKey: "scalar-failure-return",
  title:
    "an async operation that can fail must not report its failure as a bare boolean or number",
  rationale:
    "a scalar result carries no failure channel, so the caller cannot separate the operation's real answer from its error case, the reason the operation already holds is dropped at the boundary that had it, and every caller is forced to guess which way the value went, which is the collapse this codebase's outcome values exist to prevent",
  replacement:
    "declare the result as the outcome value carrying both branches, so the settled type names a failure reason beside the data, and a caller that has no use for the outcome can narrow it out explicitly instead of guessing at a scalar",
  detect({ ts, sourceFile }) {
    const hits = [];
    const report = (node, name, annotation, settled) => {
      const position = sourceFile.getLineAndCharacterOfPosition(
        node.getStart(sourceFile),
      );
      hits.push({
        line: position.line + 1,
        column: position.character + 1,
        snippet: describe(ts, name, annotation, settled),
      });
    };

    const visit = (node) => {
      if (
        ts.isFunctionDeclaration(node) &&
        node.name !== undefined &&
        isExported(ts, node) &&
        isAsync(ts, node)
      ) {
        const settled = settledTypeOf(ts, node.type);
        if (
          settled !== undefined &&
          SCALAR_RETURN_TYPES.has(settled.getText())
        ) {
          report(node, node.name.text, node.type, settled);
        }
      }
      if (ts.isVariableStatement(node) && isExported(ts, node)) {
        for (const declaration of node.declarationList.declarations) {
          const initializer = declaration.initializer;
          if (
            !ts.isIdentifier(declaration.name) ||
            initializer === undefined ||
            (!ts.isArrowFunction(initializer) &&
              !ts.isFunctionExpression(initializer)) ||
            !isAsync(ts, initializer)
          ) {
            continue;
          }
          const settled = settledTypeOf(ts, initializer.type);
          if (
            settled !== undefined &&
            SCALAR_RETURN_TYPES.has(settled.getText())
          ) {
            report(
              declaration,
              declaration.name.text,
              initializer.type,
              settled,
            );
          }
        }
      }
      ts.forEachChild(node, visit);
    };
    visit(sourceFile);
    return hits;
  },
};
