module.exports = {
  darkMode: 'class',
  content: [
    './*.{html,js,ts,jsx,tsx,mdx}',
    './{app,components,pages,src}/**/*.{html,js,ts,jsx,tsx,mdx}'
  ],
  presets: [require('./tailwind.preset')]
};
