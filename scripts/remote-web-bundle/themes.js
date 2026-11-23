// Stands in for @pierre/theming/themes: Pierre's own themes, without every Shiki theme.
import { createThemeCollection } from "./node_modules/@pierre/theming/dist/modules/createThemeCollection.js";
import { createTheme } from "./node_modules/@pierre/theming/dist/modules/createTheme.js";
import { pierreThemes } from "./node_modules/@pierre/theming/dist/collections/pierre.js";

export const themes = createThemeCollection({ themes: [pierreThemes] });
export { createTheme, pierreThemes };
