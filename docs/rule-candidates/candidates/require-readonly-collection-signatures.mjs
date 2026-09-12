const isMutableArrayType = (ts, node) =>
  node !== undefined &&
  (ts.isArrayTypeNode(node) ||
    (ts.isTypeReferenceNode(node) && node.typeName.getText() === "Array"));

export default {
  id: "require-readonly-collection-signatures",
  category: "types",
  layer: "resilience",
  tier: "grit",
  severity: "warn",
  patternKey: "readonly-collection-signature",
  title:
    "an array in a function signature or object type must be declared readonly",
  rationale:
    "a parameter typed as a mutable array hands the callee the caller's array and the caller's permission to reorder it, nothing in the signature says whether the function only reads, the mutation then travels back through an alias and surfaces far from the call, on the return side a mutable array claims the caller owns the producer's buffer and may edit it, and on an object type the property modifier only stops reassignment while leaving push and sort free to run on shared data",
  replacement:
    "type the parameter, the return and the object-type property as readonly T[] or ReadonlyArray<T>, widening a downstream API signature when it rejects readonly input rather than dropping the guarantee. class fields are deliberately out of scope, a mutable field is state the class owns rather than a value it was handed",
  detect({ ts, sourceFile }) {
    const hits = [];
    const record = (node) => {
      const position = sourceFile.getLineAndCharacterOfPosition(
        node.getStart(sourceFile),
      );
      hits.push({
        line: position.line + 1,
        column: position.character + 1,
        snippet: node.getText(sourceFile).replace(/\s+/g, " ").slice(0, 110),
      });
    };
    const visit = (node) => {
      if (ts.isParameter(node) && isMutableArrayType(ts, node.type))
        record(node);
      if (ts.isFunctionLike(node) && isMutableArrayType(ts, node.type))
        record(node.type);
      if (ts.isPropertySignature(node) && isMutableArrayType(ts, node.type))
        record(node);
      ts.forEachChild(node, visit);
    };
    visit(sourceFile);
    return hits;
  },
};
