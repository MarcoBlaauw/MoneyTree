const sharedPreset = require("../ui/tailwind.preset.js");

/** @type {import('tailwindcss').Config} */
module.exports = {
  presets: [sharedPreset],
  content: [
    "./app/**/*.{js,ts,jsx,tsx,mdx}",
    "../ui/**/*.{js,ts,jsx,tsx,mdx}"
  ],
  theme: {
    extend: {},
  },
  plugins: [],
};
