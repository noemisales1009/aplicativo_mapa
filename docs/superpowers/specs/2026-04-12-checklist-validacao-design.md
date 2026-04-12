# Checklist de Validação de Riscos Psicossociais — Design Spec

**Data:** 2026-04-12
**Autor:** Noemi / M.A.P.A.
**Status:** Draft para revisão

---

## 1. Contexto e Problema

Hoje o M.A.P.A. coleta dados psicossociais via COPSOQ II (questionário anônimo dos funcionários) e calcula a **probabilidade** de risco por setor. Porém, a **severidade** na matriz PGR é hardcoded em 4 (fixo) na view `v_pgr_report`, porque não existe um mecanismo pra avaliá-la.

Na prática, a LM Consultoria (ou o próprio gestor da empresa) faz uma **visita presencial** ao setor e aplica um checklist de validação que:
1. Confirma se o que os funcionários relataram no COPSOQ condiz com a realidade observada
2. Levanta evidências objetivas (horas extras, absenteísmo, afastamentos, queixas, rotatividade)
3. Consolida o resultado por dimensão (Confirmado / Parcial / Não confirmado)
4. Gera a **severidade real** (1-5) que, cruzada com a probabilidade do COPSOQ, produz o **grau de risco final do PGR**

Esse checklist hoje é um PDF impresso (6 páginas, 8 blocos, 21 perguntas). A ideia é digitalizá-lo dentro do M.A.P.A.

---

## 2. Objetivos

1. **Digitalizar o checklist de validação** — 8 blocos com perguntas Sim/Não/Parcialmente + campos de evidência + consolidação final
2. **Vincular ao setor** — cada checklist é de um setor específico de uma empresa
3. **Calcular a severidade** automaticamente a partir das respostas do Bloco 7 (evidências objetivas) e Bloco 8 (consolidação)
4. **Alimentar o PGR** — a severidade calculada substitui o valor fixo de 4 na view `v_pgr_report`, gerando a classificação de risco REAL
5. **Acesso por admin E gestor** — o gestor preenche o checklist do seu setor; o admin vê todos
6. **Histórico por ciclo** — cada vez que o checklist é preenchido, cria um novo registro (não sobrescreve)
7. **Mostrar contexto COPSOQ** — no topo de cada bloco, mostrar o score COPSOQ daquela dimensão pra o avaliador ter referência

## 3. Não-Objetivos

- Não gerar PDF do checklist (pode entrar depois)
- Não notificar o gestor quando o admin preencher (pode entrar depois)
- Não implementar fluxo de aprovação (admin revisa o que o gestor preencheu) — por enquanto qualquer um que tenha acesso pode salvar

---

## 4. Modelo de Acesso

| Perfil | Pode ver | Pode criar/editar |
|--------|----------|-------------------|
| **Admin** | Checklists de **todas** as empresas | Pode criar pra qualquer empresa/setor |
| **Gestor** | Só checklists da **sua empresa** | Pode criar os da sua empresa/setor |

- Rota: `/validacao` — protegida (login obrigatório), **não** admin-only
- Sidebar: item "Validação" visível pra **todos** (entre Relatórios e Configurações)
- Filtro na página: admin vê dropdown de empresas; gestor já entra filtrado

---

## 5. Schema do Banco de Dados

### 5.1 Tabela: `validation_checklists` (cabeçalho)

```sql
CREATE TABLE validation_checklists (
  id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id       BIGINT      NOT NULL REFERENCES empresas(id) ON DELETE CASCADE,
  department_id    UUID        NOT NULL REFERENCES departments(id) ON DELETE CASCADE,
  avaliador        TEXT        NOT NULL,          -- nome de quem preencheu
  participantes    TEXT,                           -- quem participou da avaliação
  data_avaliacao   DATE        NOT NULL DEFAULT CURRENT_DATE,
  severidade_calculada SMALLINT CHECK (severidade_calculada BETWEEN 1 AND 5),
  created_at       TIMESTAMPTZ DEFAULT now(),
  updated_at       TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_validation_checklists_empresa ON validation_checklists(empresa_id);
CREATE INDEX idx_validation_checklists_dept    ON validation_checklists(department_id);
```

### 5.2 Tabela: `validation_responses` (respostas individuais)

```sql
CREATE TABLE validation_responses (
  id             UUID      PRIMARY KEY DEFAULT gen_random_uuid(),
  checklist_id   UUID      NOT NULL REFERENCES validation_checklists(id) ON DELETE CASCADE,
  bloco          SMALLINT  NOT NULL CHECK (bloco BETWEEN 1 AND 8),
  pergunta_num   SMALLINT  NOT NULL,
  resposta       TEXT      CHECK (resposta IN ('sim', 'nao', 'parcialmente')),
  evidencia      TEXT,
  created_at     TIMESTAMPTZ DEFAULT now(),
  UNIQUE (checklist_id, bloco, pergunta_num)
);

CREATE INDEX idx_validation_responses_checklist ON validation_responses(checklist_id);
```

### 5.3 Tabela: `validation_consolidation` (Bloco 8 — consolidação por dimensão)

```sql
CREATE TABLE validation_consolidation (
  id             UUID      PRIMARY KEY DEFAULT gen_random_uuid(),
  checklist_id   UUID      NOT NULL REFERENCES validation_checklists(id) ON DELETE CASCADE,
  dimensao       TEXT      NOT NULL,   -- 'Demanda', 'Controle', 'Apoio', 'Relacionamento', 'Reconhecimento', 'Estresse'
  status         TEXT      NOT NULL CHECK (status IN ('confirmado', 'parcial', 'nao_confirmado')),
  created_at     TIMESTAMPTZ DEFAULT now(),
  UNIQUE (checklist_id, dimensao)
);

CREATE INDEX idx_validation_consolidation_checklist ON validation_consolidation(checklist_id);
```

### 5.4 Tabela: `validation_evidencias` (Bloco 7 — checkboxes de evidências objetivas)

```sql
CREATE TABLE validation_evidencias (
  id             UUID      PRIMARY KEY DEFAULT gen_random_uuid(),
  checklist_id   UUID      NOT NULL REFERENCES validation_checklists(id) ON DELETE CASCADE,
  tipo_evidencia TEXT      NOT NULL,   -- 'horas_extras', 'absenteismo', 'rotatividade', 'queixas_formais', 'afastamentos'
  marcado        BOOLEAN   NOT NULL DEFAULT FALSE,
  detalhamento   TEXT,                  -- campo "Detalhar" do PDF
  created_at     TIMESTAMPTZ DEFAULT now(),
  UNIQUE (checklist_id, tipo_evidencia)
);
```

### 5.5 RLS

```sql
ALTER TABLE validation_checklists    ENABLE ROW LEVEL SECURITY;
ALTER TABLE validation_responses     ENABLE ROW LEVEL SECURITY;
ALTER TABLE validation_consolidation ENABLE ROW LEVEL SECURITY;
ALTER TABLE validation_evidencias    ENABLE ROW LEVEL SECURITY;

-- Admin: acesso total a todas as tabelas
CREATE POLICY "validation_admin_all" ON validation_checklists FOR ALL USING (
  EXISTS (SELECT 1 FROM profiles WHERE profiles.id = auth.uid() AND profiles.role = 'admin')
);
CREATE POLICY "validation_responses_admin_all" ON validation_responses FOR ALL USING (
  EXISTS (SELECT 1 FROM profiles WHERE profiles.id = auth.uid() AND profiles.role = 'admin')
);
CREATE POLICY "validation_consolidation_admin_all" ON validation_consolidation FOR ALL USING (
  EXISTS (SELECT 1 FROM profiles WHERE profiles.id = auth.uid() AND profiles.role = 'admin')
);
CREATE POLICY "validation_evidencias_admin_all" ON validation_evidencias FOR ALL USING (
  EXISTS (SELECT 1 FROM profiles WHERE profiles.id = auth.uid() AND profiles.role = 'admin')
);

-- Gestor: lê e escreve só os checklists da sua empresa
CREATE POLICY "validation_gestor_own" ON validation_checklists FOR ALL USING (
  empresa_id = (SELECT empresa_id FROM profiles WHERE profiles.id = auth.uid())
);
CREATE POLICY "validation_responses_gestor_own" ON validation_responses FOR ALL USING (
  checklist_id IN (
    SELECT id FROM validation_checklists
    WHERE empresa_id = (SELECT empresa_id FROM profiles WHERE profiles.id = auth.uid())
  )
);
CREATE POLICY "validation_consolidation_gestor_own" ON validation_consolidation FOR ALL USING (
  checklist_id IN (
    SELECT id FROM validation_checklists
    WHERE empresa_id = (SELECT empresa_id FROM profiles WHERE profiles.id = auth.uid())
  )
);
CREATE POLICY "validation_evidencias_gestor_own" ON validation_evidencias FOR ALL USING (
  checklist_id IN (
    SELECT id FROM validation_checklists
    WHERE empresa_id = (SELECT empresa_id FROM profiles WHERE profiles.id = auth.uid())
  )
);
```

---

## 6. Estrutura das 21 Perguntas (8 Blocos)

Referência direta do PDF. Cada bloco tem perguntas + campo de evidência.

### Bloco 1 — Demanda de Trabalho
Dimensão COPSOQ correspondente: `Exigências Quantitativas`, `Ritmo de Trabalho`

| # | Pergunta | Opções |
|---|----------|--------|
| 1 | O volume de trabalho no setor é compatível com o número de colaboradores? | Sim / Não / Parcialmente |
| 2 | Os prazos estabelecidos são, em geral: | Adequados / Apertados / Inviáveis |
| 3 | Existe necessidade frequente de trabalhar além da jornada? | Sim / Não |
| 4 | Há períodos de sobrecarga intensa? | Sim / Não |

### Bloco 2 — Controle e Autonomia
Dimensão COPSOQ: `Influência no Trabalho`, `Possibilidade de Desenvolvimento`

| # | Pergunta | Opções |
|---|----------|--------|
| 5 | Os colaboradores têm liberdade para organizar suas tarefas? | Sim / Não / Parcialmente |
| 6 | As decisões do trabalho dependem exclusivamente da chefia? | Sim / Não |
| 7 | Há participação dos colaboradores nas decisões do setor? | Sim / Não |

### Bloco 3 — Apoio da Liderança
Dimensão COPSOQ: `Apoio Social de Superiores`, `Qualidade da Liderança`

| # | Pergunta | Opções |
|---|----------|--------|
| 8 | A liderança está disponível para orientar a equipe? | Sim / Não / Parcialmente |
| 9 | Problemas são resolvidos com apoio do gestor? | Sim / Não |
| 10 | Existe tratamento respeitoso por parte da liderança? | Sim / Não |

### Bloco 4 — Relacionamento e Clima
Dimensão COPSOQ: `Comunidade Social no Trabalho`, `Confiança Horizontal`

| # | Pergunta | Opções |
|---|----------|--------|
| 11 | Há conflitos frequentes entre colaboradores? | Sim / Não |
| 12 | Existe cooperação entre a equipe? | Sim / Não |
| 13 | O ambiente de trabalho é considerado saudável? | Sim / Não / Parcialmente |

### Bloco 5 — Reconhecimento e Valorização
Dimensão COPSOQ: `Recompensas`, `Justiça e Respeito`

| # | Pergunta | Opções |
|---|----------|--------|
| 14 | O trabalho realizado é reconhecido pela empresa? | Sim / Não / Parcialmente |
| 15 | Há feedback frequente da liderança? | Sim / Não |
| 16 | Existe valorização profissional no setor? | Sim / Não |

### Bloco 6 — Estresse e Saúde Mental
Dimensão COPSOQ: `Burnout`, `Stress`, `Sintomas Depressivos`

| # | Pergunta | Opções |
|---|----------|--------|
| 17 | Há sinais de estresse frequente na equipe? | Sim / Não |
| 18 | Já ocorreram afastamentos por problemas emocionais? | Sim / Não |
| 19 | Os colaboradores demonstram cansaço excessivo? | Sim / Não |
| 20 | O trabalho gera desgaste emocional significativo? | Sim / Não / Parcialmente |

### Bloco 7 — Evidências Objetivas (essencial para NR-1)
Não corresponde a uma dimensão COPSOQ específica — é transversal.

| # | Evidência | Tipo | Pontuação |
|---|-----------|------|-----------|
| 21a | Horas extras frequentes | Checkbox | +2 |
| 21b | Absenteísmo elevado | Checkbox | +3 |
| 21c | Rotatividade alta | Checkbox | +3 |
| 21d | Queixas formais | Checkbox | +3 |
| 21e | Afastamentos | Checkbox | +4 |
| | Campo "Detalhar" | Texto livre | — |

Score mínimo (nada marcado): 5 (base, cada evidência soma seu peso).
Correção: score = 5 + soma dos pesos das evidências marcadas.

### Bloco 8 — Consolidação Técnica (SST)
Resultado da validação por dimensão.

| Dimensão | Status |
|----------|--------|
| Demanda | Confirmado / Parcial / Não confirmado |
| Controle | Confirmado / Parcial / Não confirmado |
| Apoio | Confirmado / Parcial / Não confirmado |
| Relacionamento | Confirmado / Parcial / Não confirmado |
| Reconhecimento | Confirmado / Parcial / Não confirmado |
| Estresse | Confirmado / Parcial / Não confirmado |

---

## 7. Cálculo da Severidade

### Passo 1: Score base do Bloco 7

```
score = 5
if horas_extras:    score += 2
if absenteismo:     score += 3
if rotatividade:    score += 3
if queixas_formais: score += 3
if afastamentos:    score += 4
```

Score possível: 5 a 20 (ajustado do PDF — com base de 5 itens, mínimo 5, máximo 20).

### Passo 2: Mapear pra nível de severidade

| Score | Severidade | Nível |
|-------|-----------|-------|
| 5-6 | Muito baixa | 1 |
| 7-8 | Baixa | 2 |
| 9-10 | Média | 3 |
| 11-12 | Alta | 4 |
| 13+ | Muito alta | 5 |

### Passo 3: Ajuste pelo Bloco 8

Conta quantas dimensões foram "confirmado":
- Se 4+ dimensões confirmadas → severidade sobe 1 nível (máximo 5)
- Se 4+ dimensões não confirmadas → severidade desce 1 nível (mínimo 1)
- Caso contrário → mantém

### Resultado

O valor final (1-5) é gravado em `validation_checklists.severidade_calculada`.

---

## 8. Impacto no PGR

### View `v_pgr_report` atualizada

A severidade fixa `4 AS severity` muda para:

```sql
COALESCE(
  (SELECT vc.severidade_calculada
   FROM validation_checklists vc
   WHERE vc.department_id = exposed.department_id
   ORDER BY vc.data_avaliacao DESC
   LIMIT 1),
  4  -- fallback: se não tem checklist, usa 4
) AS severity
```

Isso pega o checklist **mais recente** daquele setor. Se não existir nenhum, mantém 4 (comportamento atual, sem regressão).

### Matriz 5×5 resultante

| Prob ↓ / Sev → | 1 (MB) | 2 (B) | 3 (M) | 4 (A) | 5 (MA) |
|---|---|---|---|---|---|
| **5 (Muito Alta)** | Médio | Alto | Alto | Crítico | Crítico |
| **4 (Alta)** | Médio | Médio | Alto | Alto | Crítico |
| **3 (Média)** | Baixo | Médio | Médio | Alto | Alto |
| **2 (Baixa)** | Baixo | Baixo | Médio | Médio | Alto |
| **1 (Muito Baixa)** | Baixo | Baixo | Baixo | Médio | Médio |

Classificação: `prob × sev` → mesma lógica atual (≤4 Baixo, ≤8 Tolerável, ≤12 Moderado, ≤16 Significativo, >16 Intolerável).

---

## 9. Página no App

### Rota e Sidebar

- Rota: `/validacao` — `ProtectedRoute` (sem `adminOnly`)
- Sidebar: item "Validação" com ícone `ClipboardCheck` (Lucide), entre Relatórios e Configurações

### Tela principal (`/validacao`)

**Layout:** lista de checklists existentes + botão "Nova Validação"

| Coluna | Conteúdo |
|--------|----------|
| Setor | Nome do departamento |
| Avaliador | Quem preencheu |
| Data | Data da avaliação |
| Severidade | Badge 1-5 com cor (verde a vermelho) |
| Status PGR | "Ativo" se é o mais recente do setor, "Histórico" se não |
| Ações | Ver / Editar |

Admin vê dropdown de empresa no topo. Gestor já vê filtrado.

### Formulário de preenchimento

**Layout:** formulário longo com 8 seções (uma por bloco), estilo accordion ou scroll contínuo.

Cada bloco mostra:
1. **Header do bloco** com nome + ícone
2. **Contexto COPSOQ** — box com score daquela dimensão (ex.: "Exigências Quantitativas: 72% — Risco Alto")
3. **Perguntas** — radio buttons (Sim/Não/Parcialmente) + textarea de evidência
4. No Bloco 7: checkboxes + textarea "Detalhar"
5. No Bloco 8: radio buttons por dimensão (Confirmado/Parcial/Não confirmado)
6. **Resultado**: severidade calculada mostrada ao final, antes de salvar

### Campos do cabeçalho

- Empresa (dropdown se admin, fixo se gestor)
- Setor (dropdown dos departamentos da empresa selecionada)
- Avaliador (texto — pré-preenche com nome do usuário logado)
- Participantes (texto livre)
- Data (date picker — padrão: hoje)

---

## 10. Arquivos do Front-end

| Ação | Arquivo | Responsabilidade |
|------|---------|------------------|
| Create | `src/pages/ValidacaoPage.tsx` | Lista de checklists + botão "Nova Validação" |
| Create | `src/pages/ValidacaoFormPage.tsx` | Formulário de preenchimento (8 blocos) |
| Create | `src/services/validacao.ts` | CRUD: fetchChecklists, createChecklist, fetchChecklistById, etc. |
| Modify | `src/components/Sidebar.tsx` | Adicionar item "Validação" no menu |
| Modify | `src/App.tsx` | Adicionar rota `/validacao` e `/validacao/novo` |
| Create | `sql/2026-04-12-checklist-validacao.sql` | Migração: CREATE TABLE + RLS + UPDATE da view |

---

## 11. Ordem de Execução

1. Criar arquivo SQL com: tabelas + RLS + view atualizada
2. Rodar no Supabase
3. Criar `src/services/validacao.ts`
4. Criar `ValidacaoPage.tsx` (lista)
5. Criar `ValidacaoFormPage.tsx` (formulário)
6. Atualizar Sidebar + App.tsx
7. Testar: preencher checklist → verificar que severidade é calculada → verificar que PGR mudou

---

## 12. Critérios de Sucesso

1. Admin e gestor conseguem acessar `/validacao`
2. Preencher os 8 blocos do checklist pra um setor específico
3. Ao salvar, a severidade é calculada automaticamente (1-5) e mostrada
4. `SELECT * FROM vw_pgr_completo WHERE grupo_homogeneo = 'Pediatria'` mostra a severidade REAL (não mais 4 fixo)
5. O PDF PGR reflete a nova severidade
6. Checklists antigos ficam como histórico (não são sobrescritos)
7. Gestor só vê os da sua empresa; admin vê todos
