export default {
  id: "require-readonly-type-members",
  category: "types",
  layer: "resilience",
  tier: "grit",
  severity: "warn",
  patternKey: "readonly-members",
  title: "every property of an object type must be readonly",
  rationale:
    "a mutable property on a shared object type lets any consumer mutate a value another layer still holds, which makes the mutation site invisible and the data flow untraceable, the type stops being a description of shape and becomes a mutable cell",
  replacement:
    "add the readonly modifier to every property signature, and when a layer genuinely needs to produce a changed copy, build a new object of the same type rather than editing one in place",
  detect({ ts, sourceFile }) {
    const hits = [];
    const visit = (node) => {
      if (ts.isTypeLiteralNode(node)) {
        for (const propertySignature of node.members) {
          const isProperty = ts.isPropertySignature(propertySignature);
          const isReadonly = propertySignature.modifiers?.some(
            (modifier) => modifier.kind === ts.SyntaxKind.ReadonlyKeyword,
          );
          if (isProperty && !isReadonly) {
            const position = sourceFile.getLineAndCharacterOfPosition(
              propertySignature.getStart(sourceFile),
            );
            hits.push({
              line: position.line + 1,
              column: position.character + 1,
              snippet: propertySignature
                .getText(sourceFile)
                .replace(/\s+/g, " ")
                .slice(0, 120),
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
