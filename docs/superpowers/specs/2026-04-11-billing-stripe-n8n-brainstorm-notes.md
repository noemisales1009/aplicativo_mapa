# Billing / Stripe / n8n — Notas de Brainstorm (PAUSADO)

**Status:** ⏸️ Pausado em 2026-04-11 por decisão da Noemi ("vamos deixar em aberto")
**Não é um spec final** — são decisões parciais pra retomar depois sem re-perguntar.

---

## Objetivo

Criar um sistema de billing SaaS para o M.A.P.A. onde:
- Cliente chega numa página → preenche dados → paga via Stripe → conta é criada automaticamente
- Provisionamento automático via n8n (orquestrador)

Isso **substitui** a ideia original de "Financeiro interno" (planilha de receitas/despesas da LM Consultoria).

---

## Decisões tomadas no brainstorm

### ✅ 1. Modelo de cobrança: **Assinatura mensal OU anual** (cliente escolhe)

- 1 Produto no Stripe
- 2 Prices: mensal e anual
- Anual com desconto de ~2 meses (~17% off) — padrão SaaS
- Cliente escolhe o intervalo no momento da compra

### ✅ 2. Planos: **1 plano único agora, estrutura preparada pra múltiplos**

- Tabela `plans` no DB desde o início, mas só com 1 linha
- Nome comercial sugerido: "M.A.P.A. Profissional"
- Tudo incluído (setores ilimitados, colaboradores ilimitados, features completas)
- Quando tiver dados de uso real, inserir Basic/Enterprise depois **sem refactor**

### ✅ 3. Trial: **Stripe Trial com cartão obrigatório**

- Cliente coloca cartão no checkout mas não é cobrado imediatamente
- Duração padrão sugerida: **7 dias** (não confirmado)
- Stripe cobra automaticamente quando o trial termina
- Técnica: parâmetro `trial_period_days` no `checkout.session.create`

### ✅ 4. Fluxo de coleta de dados: **Formulário antes do checkout (A)**

- Cliente preenche **antes** de ir pro Stripe: nome fantasia, CNPJ, nome do gestor, email, senha
- Todos os dados vão como `metadata` na sessão do Stripe Checkout
- Stripe Checkout só coleta cartão
- Reaproveitar o visual/lógica do `NewClientPage.tsx` existente
- Rota nova: `/comprar` (pública)

### ✅ 5. Landing page: **Sem landing por enquanto (C)**

- Só criar a rota `/comprar` no app
- Noemi compartilha o link manualmente (Instagram, WhatsApp, email)
- Landing dedicada fica pra depois (possivelmente em Webflow/Framer/Carrd em outro domínio)

### ✅ 6. Orquestração do pós-pagamento: **n8n**

- Noemi já tem instância de n8n rodando (confirmado pelo JSON do workflow)
- Nó `n8n-nodes-base.stripeTrigger` registra o webhook no Stripe **automaticamente** ao ativar — não precisa URL pública exposta
- Credenciais já configuradas: `Stripe account`, `Supabase CucaDigital`, `Gmail CucaDigital`
- Arquitetura: Stripe → n8n → Supabase + Gmail

---

## Pendente de decisão (quando retomar)

### ❓ Pergunta 6: Como o gestor define senha?

**(A.1)** Cliente cadastra senha no formulário antes do checkout → n8n cria usuário no Supabase Auth com email+senha dos metadata do Stripe

**(A.2)** Cliente NÃO cadastra senha no formulário → após pagamento, recebe email "clique aqui pra definir sua senha" (magic link do Supabase Auth)

Inclinação preliminar: **A.1** (mais simples, menos etapas).

### ❓ Pergunta 7: Evento do Stripe

No workflow atual da Noemi, o trigger está em `payment_intent.succeeded`. Para subscription, o correto é **`checkout.session.completed`**. Precisa ser ajustado quando retomar.

### ❓ Outras questões não abordadas

- **Duração exata do trial:** 7 dias? 14? 30?
- **Preços concretos:** quanto cobrar por mês? Por ano?
- **O que acontece no cancelamento:** fluxo `customer.subscription.deleted`
- **O que acontece em falha de cobrança:** fluxo `invoice.payment_failed` (dunning)
- **Email transacional:** continuar usando Gmail OAuth2 do n8n (que já está setado) ou migrar pra Resend/SendGrid?
- **Stripe account configurado:** produtos e prices já criados no painel do Stripe? Conta está em BR ou US?
- **Política de reembolso:** tem? Por quanto tempo?

---

## Workflow atual do n8n (criado pela Noemi em 2026-04-11)

Estrutura atual (6 nós):
1. **Stripe Trigger** (`payment_intent.succeeded`) — evento errado pra subscription, precisa trocar
2. **IF** — verifica `$json.data.object.status === 'succeeded'`
3. **Set** — placeholder vazio, precisa mapear campos
4. **Supabase Insert** — tabela `payments` (tabela ainda não existe no DB)
5. **Log de erro** — branch false do IF
6. **Gmail** — email de confirmação genérico ("obrigado pela compra")

Credenciais configuradas no n8n:
- Stripe API: `aqhRqDFNWbAuBeDV` (nome: "Stripe account")
- Supabase API: `13fzGTtAnxtag1Iq` (nome: "Supabase CucaDigital")
- Gmail OAuth2: `DRCEctlsVrJTPJh8` (nome: "Gmail CucaDigital")

**Esse workflow vai ser REAPROVEITADO e estendido** quando retomarmos. Não precisa recriar do zero.

---

## Estrutura de DB que vai ser criada (quando retomar)

```sql
-- Plano (catálogo, 1 linha por enquanto)
CREATE TABLE plans (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  stripe_product_id TEXT UNIQUE,
  nome            TEXT NOT NULL,
  descricao       TEXT,
  preco_mensal    NUMERIC(10,2),
  preco_anual     NUMERIC(10,2),
  stripe_price_monthly TEXT,
  stripe_price_annual  TEXT,
  features        JSONB,
  ativo           BOOLEAN DEFAULT true,
  created_at      TIMESTAMPTZ DEFAULT now()
);

-- Assinatura de um cliente
CREATE TABLE subscriptions (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id            BIGINT REFERENCES empresas(id),
  plan_id               UUID REFERENCES plans(id),
  stripe_customer_id    TEXT,
  stripe_subscription_id TEXT UNIQUE,
  status                TEXT CHECK (status IN ('trialing','active','past_due','canceled','incomplete')),
  interval              TEXT CHECK (interval IN ('month','year')),
  current_period_start  TIMESTAMPTZ,
  current_period_end    TIMESTAMPTZ,
  trial_ends_at         TIMESTAMPTZ,
  cancel_at             TIMESTAMPTZ,
  created_at            TIMESTAMPTZ DEFAULT now(),
  updated_at            TIMESTAMPTZ DEFAULT now()
);

-- Histórico de pagamentos (1 linha por cobrança bem-sucedida)
CREATE TABLE payments (
  id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  subscription_id          UUID REFERENCES subscriptions(id),
  stripe_payment_intent_id TEXT UNIQUE,
  amount                   NUMERIC(10,2),
  currency                 TEXT DEFAULT 'brl',
  status                   TEXT,
  paid_at                  TIMESTAMPTZ,
  created_at               TIMESTAMPTZ DEFAULT now()
);
```

**Nota:** isso é um esboço, não finalizado. Pode mudar quando retomarmos.

---

## Próximos passos quando retomar

1. Responder as perguntas pendentes (senha A.1/A.2, trial duration, preços)
2. Confirmar que Stripe está configurado pra Brasil (ou não)
3. Converter estas notas num **spec formal** em `docs/superpowers/specs/YYYY-MM-DD-billing-stripe-design.md`
4. Continuar pelo writing-plans → executing-plans

---

**Última mensagem da Noemi antes da pausa:**
> "oi, bom dia. vamos deixar essa parte de pamanto em aberto."
