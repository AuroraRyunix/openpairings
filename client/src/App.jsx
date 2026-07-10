import { Routes, Route, NavLink, useLocation, matchPath } from 'react-router-dom';
import TournamentsPage from './pages/TournamentsPage.jsx';
import TournamentPage from './pages/TournamentPage.jsx';
import FidePage from './pages/FidePage.jsx';

export default function App() {
  const location = useLocation();
  const match = matchPath('/t/:id/*', location.pathname);
  const tid = match?.params.id;

  return (
    <>
      <header className="topbar">
        <NavLink to="/" className="brand">♞ PairingsEngine</NavLink>
        <nav>
          <NavLink to="/" end>Tournaments</NavLink>
          {tid && (
            <>
              <NavLink to={`/t/${tid}/players`}>Players</NavLink>
              <NavLink to={`/t/${tid}/pairings`}>Pairings</NavLink>
              <NavLink to={`/t/${tid}/standings`}>Standings</NavLink>
              <NavLink to={`/t/${tid}/print`}>Print</NavLink>
              <NavLink to={`/t/${tid}/settings`}>Settings</NavLink>
            </>
          )}
          <NavLink to="/fide">FIDE database</NavLink>
        </nav>
      </header>
      <Routes>
        <Route path="/" element={<TournamentsPage />} />
        <Route path="/t/:id/*" element={<TournamentPage />} />
        <Route path="/fide" element={<FidePage />} />
      </Routes>
    </>
  );
}
