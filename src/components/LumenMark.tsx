/**
 * The app's mark: four viewfinder brackets around a capture dot.
 *
 * Drawn as geometry rather than an image so the brand stays crisp at every
 * scale in the titlebar, the sidebar, and the icon source.
 */
export function LumenMark({ size = 18, className }: { size?: number; className?: string }) {
  return (
    <svg
      className={className}
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      aria-hidden="true"
      focusable="false"
    >
      <path
        d="M9 3.25H5.75A2.5 2.5 0 0 0 3.25 5.75V9M15 3.25h3.25a2.5 2.5 0 0 1 2.5 2.5V9M9 20.75H5.75a2.5 2.5 0 0 1-2.5-2.5V15M15 20.75h3.25a2.5 2.5 0 0 0 2.5-2.5V15"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
      />
      <circle cx="12" cy="12" r="2.15" fill="currentColor" />
    </svg>
  );
}
