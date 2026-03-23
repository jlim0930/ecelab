// Root layout — sets page title, Elastic Cloud favicon, and global styles
import './globals.css';

export const metadata = {
  title: 'ECE Lab',
  description: 'Elastic Cloud Enterprise Lab Deployment Manager',
  icons: {
    icon: 'https://static-www.elastic.co/v3/assets/bltefdd0b53724fa2ce/blt0dc498ca4c8b3f95/5d104bbf561b9b0b537f9906/logo-cloud-32-color.svg',
  },
};

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
