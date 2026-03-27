import jsPDF from 'jspdf';
import autoTable from 'jspdf-autotable';

interface PgrRow {
  grupo_homogeneo: string;
  descricao_perigo: string;
  qtd_funcionarios: number;
  trabalhadores_expostos: number;
  incidencia: string;
  probabilidade: number;
  severidade: number;
  grau_risco: number;
  classificacao_risco: string;
  medidas_controle: string;
  score_medio: number;
}

const RISK_COLORS: Record<string, [number, number, number]> = {
  'Intolerável': [153, 27, 27],
  'Significativo': [239, 68, 68],
  'Moderado': [249, 115, 22],
  'Tolerável': [234, 179, 8],
  'Baixo': [34, 197, 94],
};

export function generatePGR(dados: PgrRow[], empresaNome: string | null) {
  const doc = new jsPDF({ orientation: 'landscape', unit: 'mm', format: 'a4' });
  const pageWidth = doc.internal.pageSize.getWidth();
  const now = new Date().toLocaleDateString('pt-BR');

  // Header
  doc.setFillColor(45, 90, 90);
  doc.rect(0, 0, pageWidth, 28, 'F');
  doc.setTextColor(255, 255, 255);
  doc.setFontSize(18);
  doc.setFont('helvetica', 'bold');
  doc.text('M.A.P.A. - Relatório PGR', 14, 12);
  doc.setFontSize(10);
  doc.setFont('helvetica', 'normal');
  doc.text(`Programa de Gerenciamento de Riscos Psicossociais | COPSOQ II`, 14, 19);
  doc.text(`${empresaNome || 'Todas as Empresas'} | Gerado em ${now}`, 14, 25);

  // Summary cards
  const setores = [...new Set(dados.map(d => d.grupo_homogeneo))];
  const totalColab = setores.reduce((acc, s) => {
    const row = dados.find(d => d.grupo_homogeneo === s);
    return acc + (row?.qtd_funcionarios || 0);
  }, 0);
  const intoleraveis = dados.filter(d => d.classificacao_risco === 'Intolerável').length;
  const significativos = dados.filter(d => d.classificacao_risco === 'Significativo').length;

  doc.setTextColor(60, 60, 60);
  doc.setFontSize(9);
  const summaryY = 35;
  const boxW = 60;
  const boxH = 16;
  const gap = 8;
  const startX = 14;

  const summaryItems = [
    { label: 'SETORES AVALIADOS', value: String(setores.length) },
    { label: 'COLABORADORES', value: String(totalColab) },
    { label: 'RISCOS INTOLERÁVEIS', value: String(intoleraveis) },
    { label: 'RISCOS SIGNIFICATIVOS', value: String(significativos) },
  ];

  summaryItems.forEach((item, i) => {
    const x = startX + i * (boxW + gap);
    doc.setFillColor(248, 250, 252);
    doc.roundedRect(x, summaryY, boxW, boxH, 2, 2, 'F');
    doc.setFontSize(7);
    doc.setFont('helvetica', 'bold');
    doc.setTextColor(148, 163, 184);
    doc.text(item.label, x + 4, summaryY + 5);
    doc.setFontSize(14);
    doc.setTextColor(30, 41, 59);
    doc.text(item.value, x + 4, summaryY + 13);
  });

  // Table
  const tableData = dados
    .sort((a, b) => b.grau_risco - a.grau_risco)
    .map(row => [
      row.grupo_homogeneo,
      row.descricao_perigo,
      String(row.qtd_funcionarios),
      String(row.trabalhadores_expostos),
      row.incidencia,
      `${row.score_medio}%`,
      String(row.probabilidade),
      String(row.severidade),
      String(row.grau_risco),
      row.classificacao_risco,
      row.medidas_controle,
    ]);

  autoTable(doc, {
    startY: summaryY + boxH + 8,
    head: [[
      'Setor', 'Categoria COPSOQ', 'Func.', 'Expostos', 'Incid.',
      'Score', 'Prob.', 'Sev.', 'Grau', 'Classificação', 'Medidas de Controle'
    ]],
    body: tableData,
    theme: 'grid',
    headStyles: {
      fillColor: [45, 90, 90],
      textColor: [255, 255, 255],
      fontSize: 7,
      fontStyle: 'bold',
      halign: 'center',
    },
    bodyStyles: {
      fontSize: 6.5,
      cellPadding: 2,
    },
    columnStyles: {
      0: { cellWidth: 28 },
      1: { cellWidth: 38 },
      2: { cellWidth: 12, halign: 'center' },
      3: { cellWidth: 14, halign: 'center' },
      4: { cellWidth: 14, halign: 'center' },
      5: { cellWidth: 14, halign: 'center' },
      6: { cellWidth: 10, halign: 'center' },
      7: { cellWidth: 10, halign: 'center' },
      8: { cellWidth: 10, halign: 'center' },
      9: { cellWidth: 22, halign: 'center' },
      10: { cellWidth: 'auto' },
    },
    didParseCell: (data) => {
      // Color the classification column
      if (data.section === 'body' && data.column.index === 9) {
        const risk = data.cell.raw as string;
        const color = RISK_COLORS[risk];
        if (color) {
          data.cell.styles.textColor = [255, 255, 255];
          data.cell.styles.fillColor = color;
          data.cell.styles.fontStyle = 'bold';
        }
      }
    },
    margin: { left: 14, right: 14 },
  });

  // Footer on each page
  const totalPages = doc.getNumberOfPages();
  for (let i = 1; i <= totalPages; i++) {
    doc.setPage(i);
    const pageH = doc.internal.pageSize.getHeight();
    doc.setFillColor(248, 250, 252);
    doc.rect(0, pageH - 10, pageWidth, 10, 'F');
    doc.setFontSize(7);
    doc.setTextColor(148, 163, 184);
    doc.text('M.A.P.A. - Monitoramento e Avaliação de Riscos Psicossociais no Ambiente de Trabalho', 14, pageH - 4);
    doc.text(`Página ${i} de ${totalPages}`, pageWidth - 14, pageH - 4, { align: 'right' });
  }

  // Download
  const fileName = `PGR_${(empresaNome || 'Geral').replace(/\s+/g, '_')}_${now.replace(/\//g, '-')}.pdf`;
  doc.save(fileName);
}
