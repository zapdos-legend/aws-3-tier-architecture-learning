import { render, screen } from '@testing-library/react';
import App from './App';

test('renders the application heading', () => {
  render(<App />);
  const heading = screen.getByRole('heading', { name: /aws 3-tier web app demo/i });
  expect(heading).toBeInTheDocument();
});
