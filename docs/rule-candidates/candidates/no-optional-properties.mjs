export default {
  id: "no-optional-properties",
  category: "types",
  layer: "resilience",
  tier: "grit",
  severity: "warn",
  patternKey: "optional-property",
  title: "an object type must not declare an optional property",
  rationale:
    "an optional property splits one type into two states the compiler cannot tell apart, it multiplies the combinations a consumer must guard at every read, and the absence is not part of the type's name so a reader cannot see which subset is valid together, the field is usually required in some flows and missing in others and the difference is a real domain distinction",
  replacement:
    "make the property required and default it at the boundary, or model the states as a discriminated union so each variant carries exactly the fields it has, reserve optionality for third-party payload shapes you do not control",
  detect({ ts, sourceFile }) {
    const hits = [];
    const visit = (node) => {
      if (ts.isPropertySignature(node) && node.questionToken !== undefined) {
        const position = sourceFile.getLineAndCharacterOfPosition(
          node.getStart(sourceFile),
        );
        hits.push({
          line: position.line + 1,
          column: position.character + 1,
          snippet: node.getText(sourceFile).replace(/\s+/g, " ").slice(0, 120),
        });
      }
      ts.forEachChild(node, visit);
    };
    visit(sourceFile);
    return hits;
  },
};
