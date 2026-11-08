import { readFileSync, readdirSync } from "node:fs";
import { join, relative } from "node:path";
import luaparse from "luaparse";

const root = new URL("..", import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1");
const tocName = readdirSync(root).find((f) => f.endsWith(".toc"));
const tocFiles = readFileSync(join(root, tocName), "utf8")
  .split(/\r?\n/)
  .filter((line) => line.trim() && !line.startsWith("#"))
  .map((line) => line.trim().replaceAll("\\", "/"));

const walk = (dir) => readdirSync(dir, { withFileTypes: true }).flatMap((entry) =>
  entry.isDirectory() ? (entry.name === "node_modules" || entry.name.startsWith(".") ? [] : walk(join(dir, entry.name)))
    : /\.(lua|xml)$/.test(entry.name) ? [relative(root, join(dir, entry.name)).replaceAll("\\", "/")] : []);
const addonFiles = walk(root);

// A name read as a global while the same file declares a local of that name
// means the read comes before the declaration, so it resolves to nil in game.
function usesBeforeDeclaration(ast) {
  const locals = new Set();
  const globalReads = [];
  const visit = (node, parent, key) => {
    if (!node || typeof node.type !== "string") return;
    if (node.type === "Identifier") {
      const isFieldName = (parent?.type === "MemberExpression" && key === "identifier")
        || (parent?.type === "TableKeyString" && key === "key");
      if (node.isLocal) locals.add(node.name);
      else if (!isFieldName) globalReads.push(node);
      return;
    }
    for (const [childKey, child] of Object.entries(node)) {
      if (Array.isArray(child)) child.forEach((c) => visit(c, node, childKey));
      else if (child && typeof child === "object") visit(child, node, childKey);
    }
  };
  visit(ast);
  return globalReads.filter((id) => locals.has(id.name));
}

// Lua 5.1 drops the backslash from an unknown escape, so "Interface\Icons" in
// source silently becomes "InterfaceIcons" in game.
function unknownEscapes(ast) {
  const found = [];
  const visit = (node) => {
    if (!node || typeof node.type !== "string") return;
    if (node.type === "StringLiteral" && /^["']/.test(node.raw)
      && /\\(?![abfnrtv"'\n\d])/.test(node.raw.replaceAll("\\\\", ""))) found.push(node);
    for (const child of Object.values(node)) {
      if (Array.isArray(child)) child.forEach(visit);
      else if (child && typeof child === "object") visit(child);
    }
  };
  visit(ast);
  return found;
}

let failed = false;
const fail = (message) => {
  console.error(message);
  failed = true;
};
for (const file of addonFiles.filter((f) => !tocFiles.includes(f))) fail(`not listed in TOC: ${file}`);
for (const file of tocFiles.filter((f) => !addonFiles.includes(f))) fail(`TOC lists missing file: ${file}`);
for (const file of addonFiles.filter((f) => f.endsWith(".lua"))) {
  let ast;
  try {
    ast = luaparse.parse(readFileSync(join(root, file), "utf8"), { luaVersion: "5.1", scope: true, locations: true });
  } catch (error) {
    fail(`${file}: ${error.message}`);
    continue;
  }
  const reported = new Set(usesBeforeDeclaration(ast).map((id) => `${file}:${id.loc.start.line}: ${id.name}`));
  for (const location of reported) fail(`${location} is used before its local declaration`);
  for (const literal of unknownEscapes(ast)) fail(`${file}:${literal.loc.start.line}: unknown escape in ${literal.raw}; write \\\\ for a backslash`);
}
console.log(failed ? "check failed" : `ok: ${addonFiles.length} files match the TOC, the Lua parses, and no local is used before it is declared`);
process.exit(failed ? 1 : 0);
