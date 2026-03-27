import logo from '../assets/logo.jpg';

interface WelcomeScreenProps {
  onStart: () => void;
}

export function WelcomeScreen({ onStart }: WelcomeScreenProps) {
  return (
    <div className="flex flex-col items-center justify-center p-6 min-h-dvh text-center fade-in-slow bg-white dark:bg-background-dark">
      <div className="mb-12">
        <img src={logo} alt="LM Consultoria" className="w-32 h-32 mx-auto mb-6 rounded-2xl object-contain" />
        <h1 className="text-3xl font-bold tracking-tight mb-4" style={{ color: '#2D5A5A' }}>
          M.A.P.A.
        </h1>
        <p className="text-xl max-w-70 mx-auto leading-relaxed font-medium" style={{ color: '#404040' }}>
          A sua voz é importante e o seu anonimato é garantido.
        </p>
      </div>

      <button
        onClick={onStart}
        style={{ backgroundColor: '#009B9B' }}
        className="w-full max-w-sm py-4 px-8 text-white rounded-2xl text-lg font-semibold shadow-sm hover:shadow-lg hover:opacity-90 transition-all scale-click"
      >
        Iniciar Mapeamento
      </button>
    </div>
  );
}
