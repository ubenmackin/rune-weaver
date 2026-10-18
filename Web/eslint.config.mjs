// Rune Weaver Dashboard — ESLint flat config for TS/TSX sources and CSS.
import js from "@eslint/js";
import tseslint from "typescript-eslint";
import reactHooks from "eslint-plugin-react-hooks";
import css from "@eslint/css";

export default tseslint.config(
  {
    ignores: ["dist/**", "node_modules/**", "**/*.d.ts"],
    linterOptions: {
      reportUnusedDisableDirectives: "off",
    },
  },
  {
    files: ["src/**/*.{js,mjs,cjs,ts,tsx}"],
    extends: [js.configs.recommended, ...tseslint.configs.recommended],
    plugins: {
      "react-hooks": reactHooks,
    },
    rules: {
      ...reactHooks.configs.recommended.rules,
      // tsc already handles unused variables strictly via noUnusedLocals and noUnusedParameters
      "@typescript-eslint/no-unused-vars": "off",
      "@typescript-eslint/no-empty-object-type": "off",
      "@typescript-eslint/no-explicit-any": "warn",
      "no-control-regex": "off",
      "no-empty": ["error", { allowEmptyCatch: true }],
      "no-useless-escape": "warn",
      "prefer-const": "warn",
    },
  },
  {
    files: ["src/**/*.test.{ts,tsx}", "src/**/test-utils/**/*.{ts,tsx}"],
    rules: {
      "@typescript-eslint/no-explicit-any": "off",
    },
  },
  {
    files: ["src/**/*.css"],
    plugins: {
      css,
    },
    language: "css/css",
    rules: {
      ...css.configs.recommended.rules,
      "css/no-invalid-properties": ["error", { allowUnknownVariables: true }],
      "css/use-baseline": "off",
      "css/no-important": "off",
    },
  },
);
