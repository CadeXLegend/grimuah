const MINIMUM_BODY_LENGTH = 30;

let cachedCorpus;
let cachedGroups;

// group every named function and arrow const by name plus its exact body text,
// whitespace collapsed. two declarations in the same group are byte-identical
// implementations of the same helper
const collectGroups = (ts, corpus) => {
  const groups = new Map();
  for (const file of corpus) {
    const add = (name, body) => {
      const text = body.getText(file.sourceFile).replace(/\s+/g, " ").trim();
      if (text.length < MINIMUM_BODY_LENGTH) return;
      const key = `${name}|${text}`;
      const entry = groups.get(key) ?? { files: new Set(), count: 0 };
      entry.files.add(file.relPath);
      entry.count += 1;
      groups.set(key, entry);
    };
    const visit = (node) => {
      if (
        ts.isFunctionDeclaration(node) &&
        node.name !== undefined &&
        node.body !== undefined
      ) {
        add(node.name.text, node.body);
      }
      if (
        ts.isVariableDeclaration(node) &&
        ts.isIdentifier(node.name) &&
        node.initializer !== undefined
      ) {
        const initializer = node.initializer;
        const isFunction =
          ts.isArrowFunction(initializer) ||
          ts.isFunctionExpression(initializer);
        if (isFunction && initializer.body !== undefined)
          add(node.name.text, initializer.body);
      }
      ts.forEachChild(node, visit);
    };
    visit(file.sourceFile);
  }
  return groups;
};

export default {
  id: "no-duplicated-function-body",
  category: "patterns",
  layer: "resilience",
  tier: "prepass",
  severity: "warn",
  patternKey: "duplicated-function-body",
  title:
    "a function whose body is identical to the same-named function in another file must be lifted to a shared module",
  rationale:
    "an identical copy is not a coincidence, it is the same decision written twice, so a fix or a rule change has to be found and applied in every copy, and the copies drift one bug report at a time because nothing marks them as related, the compiler sees two independent functions and so does every reader",
  replacement:
    "move the implementation into the shared library and import it, keeping one declaration whose name is the single answer to what the helper does",
  detect({ ts, sourceFile, relPath, corpus }) {
    if (cachedCorpus !== corpus) {
      cachedCorpus = corpus;
      cachedGroups = collectGroups(ts, corpus);
    }
    const groups = cachedGroups;
    const hits = [];
    const check = (name, body) => {
      const text = body.getText(sourceFile).replace(/\s+/g, " ").trim();
      if (text.length < MINIMUM_BODY_LENGTH) return;
      const entry = groups.get(`${name}|${text}`);
      if (entry === undefined || entry.files.size < 2) return;
      const position = sourceFile.getLineAndCharacterOfPosition(
        body.getStart(sourceFile),
      );
      hits.push({
        line: position.line + 1,
        column: position.character + 1,
        snippet: `${name} is a byte-identical copy, ${entry.count} copies across ${entry.files.size} files`,
      });
    };
    const visit = (node) => {
      if (
        ts.isFunctionDeclaration(node) &&
        node.name !== undefined &&
        node.body !== undefined
      )
        check(node.name.text, node.body);
      if (
        ts.isVariableDeclaration(node) &&
        ts.isIdentifier(node.name) &&
        node.initializer !== undefined
      ) {
        const initializer = node.initializer;
        if (
          (ts.isArrowFunction(initializer) ||
            ts.isFunctionExpression(initializer)) &&
          initializer.body !== undefined
        ) {
          check(node.name.text, initializer.body);
        }
      }
      ts.forEachChild(node, visit);
    };
    visit(sourceFile);
    return hits;
  },
};
