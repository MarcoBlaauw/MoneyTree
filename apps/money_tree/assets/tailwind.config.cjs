const path = require("path");

const uiPreset = require("../ui/tailwind.preset.js");

/** @type {import('tailwindcss').Config} */
module.exports = {
  presets: [uiPreset],
  content: [
    path.resolve(__dirname, "..", "lib", "**/*.{ex,heex,leex,sface}"),
    path.resolve(__dirname, "js", "**/*.{js,ts,jsx,tsx}"),
    path.resolve(__dirname, "css", "**/*.{css,pcss}")
  ],
  theme: {
    extend: {}
  },
  plugins: []
};
