

interface ProgressBarProps {
  current: number;
  total: number;
  categoryName?: string;
}

export function ProgressBar({ current, total, categoryName }: ProgressBarProps) {
  const percentage = Math.round((current / total) * 100);

  return (
    <div className="w-full mb-12 mt-6">
      <div className="flex justify-between items-end mb-4">
        <div>
          <h2 className="text-sm font-semibold uppercase tracking-widest" style={{ color: '#009B9B' }}>
            Seção: {categoryName ?? 'Ambiente de Trabalho'}
          </h2>
          <p className="text-2xl font-display font-medium mt-1" style={{ color: '#2D5A5A' }}>Pergunta {current} de {total}</p>
        </div>
        <div className="text-right">
          <span className="font-bold text-lg" style={{ color: '#009B9B' }}>{percentage}%</span>
        </div>
      </div>
      <div className="w-full h-3 bg-slate-200 rounded-full overflow-hidden">
        <div
          className="h-full transition-all duration-700 ease-out rounded-full"
          style={{ width: `${percentage}%`, backgroundColor: '#009B9B', boxShadow: '0 0 15px rgba(0, 155, 155, 0.3)' }}
        ></div>
      </div>
    </div>
  );
}
