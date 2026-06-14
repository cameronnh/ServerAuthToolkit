import fs from "fs"
import path from "path"
import { fileURLToPath } from "url"

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const root = path.join(__dirname, "..")
const wallyPath = path.join(root, "wally.toml")
const readmePath = path.join(root, "README.md")

const wally = fs.readFileSync(wallyPath, "utf8")
const nameMatch = wally.match(/^name\s*=\s*"([^"]+)"/m)
const versionMatch = wally.match(/^version\s*=\s*"([^"]+)"/m)

if (!nameMatch || !versionMatch) {
	console.error("Could not parse name or version from wally.toml")
	process.exit(1)
}

const packageSpec = `${nameMatch[1]}@${versionMatch[1]}`
const dependencyLine = `ServerAuthToolkit = "${packageSpec}"`

let readme = fs.readFileSync(readmePath, "utf8")
const linePattern = /^ServerAuthToolkit = "[^"]+"$/m

if (!linePattern.test(readme)) {
	console.error('Could not find `ServerAuthToolkit = "..."` line in README.md')
	process.exit(1)
}

readme = readme.replace(linePattern, dependencyLine)
fs.writeFileSync(readmePath, readme)
console.log(`Synced README.md from wally.toml: ${dependencyLine}`)
