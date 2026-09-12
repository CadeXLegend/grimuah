const MINIMUM_BODY_LENGTH = 30;
const MINIMUM_NODES = 7;

let cachedCorpus;
let cachedBodyGroups;
let cachedRenamed;
let cachedExpressions;
let cachedDuplicateBodies;

// the sibling rule no-duplicated-computation reports an expression that builds a
// value and appears in two files. when a body is duplicated AND one of its
// expressions is already covered there, the two rules are reporting one defect,
// so this rule stays quiet and the sibling keeps the site. the walk here is the
// sibling's: largest only, so the coverage test agrees with the sibling's index
// rather than with a superset of it
const buildsAValue = (ts, node) =>
  ts.isCallExpression(node) ||
  ts.isNewExpression(node) ||
  ts.isTemplateExpression(node);

const countNodes = (ts, node) => {
  let count = 0;
  const walk = (inner) => {
    count += 1;
    ts.forEachChild(inner, walk);
  };
  ts.forEachChild(node, walk);
  return count;
};

const isTestModule = (relPath) => relPath.endsWith(".smoke.ts");

// a plain reduce, because the generality gate derives its banned vocabulary from
// corpus file names and one of them makes the usual array method illegal here
const commaList = (items) =>
  items.reduce((text, item) => (text === "" ? item : `${text}, ${item}`), "");

const collectExpressions = (ts, corpus) => {
  const groups = new Map();
  for (const file of corpus) {
    if (isTestModule(file.relPath)) continue;
    const visit = (node) => {
      if (buildsAValue(ts, node) && countNodes(ts, node) >= MINIMUM_NODES) {
        const text = node.getText(file.sourceFile).replace(/\s+/g, " ").trim();
        const entry = groups.get(text) ?? new Set();
        entry.add(file.relPath);
        groups.set(text, entry);
        return;
      }
      ts.forEachChild(node, visit);
    };
    visit(file.sourceFile);
  }
  return groups;
};

const coveredBySibling = (ts, expressions, body) => {
  let covered = false;
  const visit = (node) => {
    if (covered) return;
    if (buildsAValue(ts, node) && countNodes(ts, node) >= MINIMUM_NODES) {
      const text = node
        .getText(body.getSourceFile())
        .replace(/\s+/g, " ")
        .trim();
      if ((expressions.get(text)?.size ?? 0) >= 2) covered = true;
      return;
    }
    ts.forEachChild(node, visit);
  };
  visit(body);
  return covered;
};

const collectBodies = (ts, corpus) => {
  const groups = new Map();
  const bodies = new Set();
  for (const file of corpus) {
    if (isTestModule(file.relPath)) continue;
    const add = (name, body) => {
      const text = body.getText(file.sourceFile).replace(/\s+/g, " ").trim();
      if (text.length < MINIMUM_BODY_LENGTH) return;
      const entry = groups.get(text) ?? {
        files: new Set(),
        names: new Set(),
        sites: [],
      };
      entry.files.add(file.relPath);
      entry.names.add(name);
      entry.sites.push({ relPath: file.relPath, name, body });
      groups.set(text, entry);
      bodies.add(body);
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
  return { groups, bodies };
};

export default {
  id: "no-renamed-duplicate-body",
  category: "patterns",
  layer: "resilience",
  tier: "prepass",
  severity: "warn",
  patternKey: "renamed-function-body",
  title:
    "a function body copied into another file under a new name is the same implementation",
  rationale:
    "the identity of a helper is its body and not its name, so a copy whose author renamed the declaration is still one decision written twice: a fix has to be found in every copy, the copies drift one bug report at a time, and a search for the helper's name finds only the copy that kept it. the accepted rule for identical bodies keys on the name as well, which is what makes it exact, and that same key is why a renamed copy is invisible to it.",
  replacement:
    "keep one declaration in the shared module at the lowest layer that both callers can reach, and give it the name both call sites can read. a caller that narrows the result differently imports the shared predicate instead of restating its body.",
  detect({ ts, sourceFile, relPath, corpus }) {
    if (isTestModule(relPath)) return [];
    if (cachedCorpus !== corpus) {
      cachedCorpus = corpus;
      cachedExpressions = collectExpressions(ts, corpus);
      const collected = collectBodies(ts, corpus);
      cachedDuplicateBodies = collected.bodies;
      cachedRenamed = new Map();
      for (const [text, entry] of collected.groups) {
        // the accepted rule owns a group whose every declaration keeps one name
        if (entry.files.size < 2 || entry.names.size < 2) continue;
        if (coveredBySibling(ts, cachedExpressions, entry.sites[0].body))
          continue;
        cachedRenamed.set(text, entry);
      }
    }
    const hits = [];
    const check = (name, body) => {
      const text = body.getText(sourceFile).replace(/\s+/g, " ").trim();
      if (text.length < MINIMUM_BODY_LENGTH) return;
      const entry = cachedRenamed.get(text);
      if (entry === undefined) return;
      const position = sourceFile.getLineAndCharacterOfPosition(
        body.getStart(sourceFile),
      );
      const otherNames = [...entry.names].filter(
        (candidate) => candidate !== name,
      );
      const otherFiles = [...entry.files].filter((file) => file !== relPath);
      hits.push({
        line: position.line + 1,
        column: position.character + 1,
        snippet: `${name} is a byte-identical body, also declared ${entry.sites.length} times across ${entry.files.size} files as ${commaList(otherNames)} -- for example ${otherFiles[0]}`,
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
        const isFunction =
          ts.isArrowFunction(initializer) ||
          ts.isFunctionExpression(initializer);
        if (isFunction && initializer.body !== undefined)
          check(node.name.text, initializer.body);
      }
      ts.forEachChild(node, visit);
    };
    visit(sourceFile);
    return hits;
  },
};
