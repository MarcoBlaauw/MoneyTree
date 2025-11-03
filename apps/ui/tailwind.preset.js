const defaultTheme = require('tailwindcss/defaultTheme');

const brandColors = {
  primary: {
    DEFAULT: '#0b3d2e',
    foreground: '#f5f9f4'
  },
  secondary: {
    DEFAULT: '#4f9c6b',
    foreground: '#052216'
  },
  accent: {
    DEFAULT: '#b68f2d',
    foreground: '#1f1400'
  },
  success: {
    DEFAULT: '#10b981',
    foreground: '#022c22'
  },
  warning: {
    DEFAULT: '#f59e0b',
    foreground: '#78350f'
  },
  danger: {
    DEFAULT: '#ef4444',
    foreground: '#7f1d1d'
  },
  neutral: {
    DEFAULT: '#1f2937',
    foreground: '#f9fafb'
  }
};

const radii = {
  none: '0px',
  sm: '0.125rem',
  DEFAULT: '0.375rem',
  md: '0.5rem',
  lg: '0.75rem',
  xl: '1rem',
  full: '9999px'
};

const typography = ({ theme }) => ({
  DEFAULT: {
    css: {
      '--tw-prose-body': theme('colors.neutral.700'),
      '--tw-prose-headings': theme('colors.neutral.DEFAULT'),
      '--tw-prose-links': theme('colors.primary.DEFAULT'),
      '--tw-prose-bold': theme('colors.neutral.DEFAULT'),
      '--tw-prose-counters': theme('colors.neutral.500'),
      '--tw-prose-bullets': theme('colors.neutral.300'),
      '--tw-prose-hr': theme('colors.neutral.200'),
      '--tw-prose-quotes': theme('colors.neutral.DEFAULT'),
      '--tw-prose-quote-borders': theme('colors.primary.DEFAULT'),
      '--tw-prose-code': theme('colors.accent.DEFAULT')
    }
  }
});

module.exports = {
  theme: {
    extend: {
      colors: {
        ...brandColors,
        background: '#0d1f16',
        foreground: '#f2f8f4',
        muted: '#6b8c79'
      },
      borderRadius: radii,
      boxShadow: {
        sm: '0 1px 2px 0 rgb(15 23 42 / 0.05)',
        DEFAULT: '0 10px 15px -3px rgb(15 23 42 / 0.1), 0 4px 6px -4px rgb(15 23 42 / 0.1)',
        md: '0 20px 25px -5px rgb(15 23 42 / 0.1), 0 10px 10px -5px rgb(15 23 42 / 0.04)',
        lg: '0 25px 50px -12px rgb(15 23 42 / 0.25)',
        inner: 'inset 0 2px 4px 0 rgb(15 23 42 / 0.06)'
      },
      fontFamily: {
        sans: ['Inter', ...defaultTheme.fontFamily.sans],
        mono: ['JetBrains Mono', ...defaultTheme.fontFamily.mono]
      },
      typography
    }
  },
  plugins: [require('@tailwindcss/forms'), require('@tailwindcss/typography')]
};
