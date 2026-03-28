
export type LikertValue = 5 | 4 | 3 | 2 | 1;

export interface LikertOptionProps {
  label: string;
  emoji: string;
  value: LikertValue;
  colorClass: string;
  onClick: (value: LikertValue) => void;
  index: number;
}

export function LikertOption({ label, emoji, value, colorClass, onClick, index }: LikertOptionProps) {
  return (
    <button
      onClick={() => onClick(value)}
      className={`group flex flex-col items-center p-8 rounded-2xl bg-white border-2 border-transparent shadow-sm hover:shadow-xl transition-all ${colorClass}`}
      style={{ animationDelay: `${0.1 + (index * 0.05)}s` }}
    >
      <div className="text-5xl mb-4 group-hover:scale-110 transition-transform" role="img" aria-label={label}>{emoji}</div>
      <span className="text-sm font-bold mb-1" style={{ color: '#404040' }}>{value}</span>
      <span className="font-semibold text-lg" style={{ color: '#2D5A5A' }}>{label}</span>
    </button>
  );
}

export const LIKERT_CHOICES = [
  { value: 1 as LikertValue, label: 'Nunca',          emoji: '😊', colorClass: 'hover:border-green-400 focus:border-green-400 hover:bg-green-50' },
  { value: 2 as LikertValue, label: 'Raramente',      emoji: '🙂', colorClass: 'hover:border-lime-400 focus:border-lime-400 hover:bg-lime-50' },
  { value: 3 as LikertValue, label: 'Às vezes',       emoji: '😐', colorClass: 'hover:border-amber-400 focus:border-amber-400 hover:bg-amber-50' },
  { value: 4 as LikertValue, label: 'Frequentemente', emoji: '😰', colorClass: 'hover:border-orange-400 focus:border-orange-400 hover:bg-orange-50' },
  { value: 5 as LikertValue, label: 'Sempre',         emoji: '😫', colorClass: 'hover:border-red-400 focus:border-red-400 hover:bg-red-50' },
];
