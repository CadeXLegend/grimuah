const MINIMUM_NODES = 7;

let cachedCorpus;
let cachedGroups;
let cachedBodyGroups;

// the sibling rule no-duplicated-function-body already reports an identical body,
// so a computation inside one of those bodies is the same finding at the same
// line. measured: randomIntInclusive is a byte-identical arrow in three services,
// and its expression body is one of this rule's sites. the accepted rule wins and
// this one stays quiet, which is the one idea or two test in section 6.7 of the
// report
const MINIMUM_BODY_LENGTH = 30;

const collectDuplicateBodies = (ts, corpus) => {
  const groups = new Map();
  for (const file of corpus) {
    const add = (name, body) => {
      const text = body.getText(file.sourceFile).replace(/\s+/g, " ").trim();
      if (text.length < MINIMUM_BODY_LENGTH) return;
      const key = `${name}|${text}`;
      const entry = groups.get(key) ?? { files: new Set(), bodies: new Set() };
      entry.files.add(file.relPath);
      entry.bodies.add(body);
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
  const duplicated = new Set();
  for (const entry of groups.values()) {
    if (entry.files.size < 2) continue;
    for (const body of entry.bodies) duplicated.add(body);
  }
  return duplicated;
};

const insideDuplicateBody = (ts, duplicatedBodies, node) => {
  let current = node.parent;
  while (current !== undefined) {
    if (duplicatedBodies.has(current)) return true;
    if (ts.isSourceFile(current)) return false;
    current = current.parent;
  }
  return false;
};

// the size of an expression is the number of its descendant nodes, so a
// two-token expression stays out: a repeat of `a + b` is the language, not a
// formula
const countNodes = (ts, node) => {
  let count = 0;
  const walk = (inner) => {
    count += 1;
    ts.forEachChild(inner, walk);
  };
  ts.forEachChild(node, walk);
  return count;
};

// an expression that builds a value: a call, a construction or a template. a
// comparison, a logical chain and a nullish ladder test a value instead, and the
// corpus writes those the same way in ten files as its own dialect.
const buildsAValue = (ts, node) =>
  ts.isCallExpression(node) ||
  ts.isNewExpression(node) ||
  ts.isTemplateExpression(node);

const isTestModule = (relPath) => relPath.endsWith(".smoke.ts");

const collectGroups = (ts, corpus) => {
  const groups = new Map();
  for (const file of corpus) {
    if (isTestModule(file.relPath)) continue;
    const visit = (node) => {
      if (buildsAValue(ts, node) && countNodes(ts, node) >= MINIMUM_NODES) {
        const text = node.getText(file.sourceFile).replace(/\s+/g, " ").trim();
        const entry = groups.get(text) ?? { files: new Set(), count: 0 };
        entry.files.add(file.relPath);
        entry.count += 1;
        groups.set(text, entry);
        // largest only: a sub-expression of a counted expression is not a site
        return;
      }
      ts.forEachChild(node, visit);
    };
    visit(file.sourceFile);
  }
  return groups;
};

export default {
  id: "no-duplicated-computation",
  category: "patterns",
  layer: "resilience",
  tier: "prepass",
  severity: "warn",
  patternKey: "duplicated-expression",
  title:
    "a computation written twice in two files must be extracted into a shared function",
  rationale:
    "an identical expression in two modules is one decision written twice: a change to the unit, the rounding or the route has to be found and applied in both copies, and the copies drift one bug report at a time because nothing marks them as related. the compiler sees two independent expressions, so does the reader, and the second copy is invisible to any search that looks for a call by name. the repo mandate states it plainly: do not write the same derived computation twice, extract it.",
  replacement:
    "extract the expression into a named function in the shared module at the bottom of the dependency order and call it from both places, so the formula has one home and one name.",
  detect({ ts, sourceFile, relPath, corpus }) {
    if (isTestModule(relPath)) return [];
    if (cachedCorpus !== corpus) {
      cachedCorpus = corpus;
      cachedGroups = collectGroups(ts, corpus);
      cachedBodyGroups = collectDuplicateBodies(ts, corpus);
    }
    const hits = [];
    const visit = (node) => {
      if (buildsAValue(ts, node) && countNodes(ts, node) >= MINIMUM_NODES) {
        const text = node.getText(sourceFile).replace(/\s+/g, " ").trim();
        const entry = cachedGroups.get(text);
        if (
          entry !== undefined &&
          entry.files.size >= 2 &&
          !insideDuplicateBody(ts, cachedBodyGroups, node)
        ) {
          const position = sourceFile.getLineAndCharacterOfPosition(
            node.getStart(sourceFile),
          );
          const others = [...entry.files]
            .filter((file) => file !== relPath)
            .reduce(
              (list, file) => (list === "" ? file : `${list}, ${file}`),
              "",
            );
          hits.push({
            line: position.line + 1,
            column: position.character + 1,
            snippet: `${text.slice(0, 60)} -- the same computation is written in ${others}`,
          });
        }
        return;
      }
      ts.forEachChild(node, visit);
    };
    visit(sourceFile);
    return hits;
  },
};
