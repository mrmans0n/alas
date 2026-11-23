// Stands in for the highlighter backends the web client never selects: the Highlights engine and
// Shiki's WebAssembly engine. The default, Shiki's JavaScript engine, is bundled.
const unused = () => { throw new Error("Not bundled in the Alas web client"); };
export const codeToTokens = unused;
export const isSupportedLanguage = () => false;
export const LiveTokenizer = class { constructor() { unused(); } };
export const createOnigurumaEngine = unused;
export default unused;
