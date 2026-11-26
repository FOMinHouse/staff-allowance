-- Sale items and the staff discount ("rule B").
--
-- Shopify prices the sale (products.rsp = the sale price while a sale runs), so a staff discount of 40% was
-- being taken off an already marked-down price. Rule B: on a sale item, staff pay the LOWER of
--   (a) the sale price, and
--   (b) their normal staff price = the original (compare-at) price less the staff discount.
-- So the discount never stacks on a sale, and a shallow sale (say 14% off) never makes an item dearer than
-- the usual staff price. Allowance orders are unchanged (they deduct the current price) and so is the
-- pay-in part of a split order (full current price).
--
-- Needs the original price, which the Shopify sync did not store: products.compare_at (Shopify's compareAtPrice,
-- only while it is above the price), filled in by the 15-minute shopify-stock sync via apply_shopify_sync.
-- The rule lives in _order_plan() (what is quoted and charged) and validate_order_amount() (the trigger that
-- checks every order row) — keep both, and index.html's staffUnitPrice(), in step.
-- Safe to re-run.

alter table products add column if not exists compare_at numeric;
comment on column products.compare_at is $c$Shopify's compare-at (original) price while the item is on sale, otherwise null. Set by the 15-minute Shopify sync (apply_shopify_sync). Staff discount orders on a sale item pay the LOWER of rsp (the sale price) and compare_at * (1 - staff discount); see _order_plan() and validate_order_amount().$c$;

-- Bridge until the next sync run (<= 15 min) writes Shopify's real compare-at prices: treat an item whose price
-- dropped since 20 Nov and is still at that dropped price as on sale, with the previous price as the original.
update products p set compare_at = l.old_rsp
  from (select distinct on (sku) sku, old_rsp, new_rsp
          from product_price_log
         where old_rsp is not null and changed_at >= '2026-11-20'
         order by sku, changed_at desc) l
 where l.sku = p.sku and l.new_rsp = p.rsp and l.old_rsp > l.new_rsp and p.compare_at is null;

CREATE OR REPLACE FUNCTION public._order_plan(p_order_type text, p_items jsonb, p_balance numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_discount_rate constant numeric := 0.40; -- keep in sync with CONFIG.DISCOUNT_RATE and validate_order_amount()
  v_item record;
  v_lines jsonb := '[]'::jsonb;
  v_remaining numeric := greatest(coalesce(p_balance, 0), 0);
  v_covered int;
  v_topup int;
  v_total_rsp numeric := 0;
  v_allowance_total numeric := 0;
  v_topup_total numeric := 0;
  v_payable_total numeric := 0;
  v_amount numeric;
  v_unit numeric;
begin
  if p_order_type not in ('allowance','discount') then
    raise exception 'BAD_REQUEST: unknown order type';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'BAD_REQUEST: empty cart';
  end if;
  if jsonb_array_length(p_items) > 50 then
    raise exception 'BAD_REQUEST: too many lines in one order';
  end if;

  for v_item in
    with raw as (
      select e->>'sku' as sku,
             case when (e->>'qty') ~ '^[0-9]{1,4}$' then (e->>'qty')::int else null end as qty,
             pos
      from jsonb_array_elements(p_items) with ordinality as t(e, pos)
    ), merged as (
      select sku, sum(qty)::int as qty, min(pos) as pos, bool_or(qty is null) as bad_qty
      from raw group by sku
    )
    select m.sku, m.qty, m.bad_qty, p.product, p.rsp, p.compare_at, p.available
    from merged m left join products p on p.sku = m.sku
    order by m.pos
  loop
    if v_item.bad_qty or v_item.qty is null or v_item.qty < 1 or v_item.qty > 20 then
      raise exception 'BAD_QTY: %', v_item.sku;
    end if;
    if v_item.product is null then
      raise exception 'UNKNOWN_PRODUCT: %', v_item.sku;
    end if;
    if not (v_item.rsp > 0) then
      raise exception 'NOT_PRICED: %', v_item.product;
    end if;
    if coalesce(v_item.available, 0) < v_item.qty then
      raise exception 'OUT_OF_STOCK: %', v_item.product;
    end if;

    v_total_rsp := v_total_rsp + v_item.rsp * v_item.qty;

    if p_order_type = 'discount' then
      -- sale item: the lower of the sale price and the normal staff price; otherwise the normal staff price
      v_unit := case when v_item.compare_at > v_item.rsp
                     then least(v_item.rsp, v_item.compare_at * (1 - v_discount_rate))
                     else v_item.rsp * (1 - v_discount_rate) end;
      v_amount := round(v_unit * v_item.qty, 2);
      v_payable_total := v_payable_total + v_amount;
      v_lines := v_lines || jsonb_build_object('sku', v_item.sku, 'product', v_item.product, 'qty', v_item.qty,
        'order_type', 'discount', 'rsp', v_item.rsp, 'amount', v_amount, 'is_topup', false);
    else
      v_covered := least(v_item.qty, floor(v_remaining / v_item.rsp)::int);
      v_topup := v_item.qty - v_covered;
      if v_covered > 0 then
        v_amount := v_item.rsp * v_covered;
        v_remaining := v_remaining - v_amount;
        v_allowance_total := v_allowance_total + v_amount;
        v_lines := v_lines || jsonb_build_object('sku', v_item.sku, 'product', v_item.product, 'qty', v_covered,
          'order_type', 'allowance', 'rsp', v_item.rsp, 'amount', v_amount, 'is_topup', false);
      end if;
      if v_topup > 0 then
        v_amount := v_item.rsp * v_topup;
        v_topup_total := v_topup_total + v_amount;
        v_lines := v_lines || jsonb_build_object('sku', v_item.sku, 'product', v_item.product, 'qty', v_topup,
          'order_type', 'discount', 'rsp', v_item.rsp, 'amount', v_amount, 'is_topup', true);
      end if;
    end if;
  end loop;

  return jsonb_build_object(
    'lines', v_lines,
    'total_rsp', v_total_rsp,
    'allowance_total', v_allowance_total,
    'topup_total', v_topup_total,
    'payable_total', v_payable_total,
    'is_split', v_topup_total > 0
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.validate_order_amount()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_rsp numeric;
  v_compare numeric;
  v_expected numeric;
begin
  if auth.jwt() is null or auth.jwt()->>'email' = 'musa@freedomofmovement.co.za' then
    return new;
  end if;

  select rsp, compare_at into v_rsp, v_compare from products where sku = new.sku;
  if v_rsp is null then
    raise exception 'Unknown SKU %', new.sku;
  end if;
  if new.rsp is distinct from v_rsp then
    raise exception 'RSP mismatch for % — submitted % but catalog says %', new.sku, new.rsp, v_rsp;
  end if;

  if new.order_type = 'discount' and not new.is_topup then
    -- same rule as _order_plan(): on a sale item, the lower of the sale price and the normal staff price
    v_expected := round(case when v_compare > v_rsp
                             then least(v_rsp, v_compare * (1 - 0.40))
                             else v_rsp * (1 - 0.40) end * new.qty, 2);
  else
    v_expected := v_rsp * new.qty;
  end if;
  if abs(new.amount - v_expected) > 0.01 then
    raise exception 'Amount mismatch for % — submitted % but expected %', new.sku, new.amount, v_expected;
  end if;

  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.apply_shopify_sync(items jsonb, p_dry boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_stock int; v_prices int; v_added int; v_cats int; v_zero int; v_feed int; v_compare int;
begin
  create temp table _s on commit drop as
  select x->>'sku' as sku,
         max((x->>'available')::numeric) as available,
         bool_or(coalesce((x->>'active')::boolean, false)) as active,
         max(nullif(x->>'price','')::numeric) filter (where coalesce((x->>'active')::boolean,false)) as price,
         max(x->>'name') as name,
         max(nullif(x->>'category','')) as category,
         bool_or(jsonb_exists(x, 'compare_at')) as has_ca,
         max(nullif(x->>'compare_at','')::numeric) filter (where coalesce((x->>'active')::boolean,false)) as compare_at
    from jsonb_array_elements(items) x
   where coalesce(x->>'sku','') <> ''
   group by x->>'sku';
  select count(*) into v_feed from _s;

  select count(*) into v_stock from products p join _s s on s.sku = p.sku where p.available is distinct from s.available;

  create temp table _price on commit drop as
  select p.sku, p.product, p.rsp as old_rsp, s.price as new_rsp, p.available
    from products p join _s s on s.sku = p.sku
   where s.active and s.price > 0 and p.rsp is distinct from s.price;
  select count(*) into v_prices from _price;

  -- the original (compare-at) price, kept only while it is above the selling price. Only for SKUs whose feed row
  -- carries the field, so a sync that does not send it never wipes it.
  create temp table _ca on commit drop as
  select p.sku, case when s.compare_at > s.price then s.compare_at end as compare_at
    from products p join _s s on s.sku = p.sku
   where s.active and s.price > 0 and s.has_ca
     and p.compare_at is distinct from (case when s.compare_at > s.price then s.compare_at end);
  select count(*) into v_compare from _ca;

  -- new SKUs are only added once they have stock at FOM Online
  create temp table _new on commit drop as
  select s.sku, coalesce(nullif(s.name,''), s.sku) as product, s.category, s.price as rsp, s.available,
         case when s.compare_at > s.price then s.compare_at end as compare_at
    from _s s
   where s.active and s.price > 0 and s.available > 0 and not exists (select 1 from products p where p.sku = s.sku);
  select count(*) into v_added from _new;

  create temp table _cat on commit drop as
  select p.sku, s.category
    from products p join _s s on s.sku = p.sku
   where s.category is not null and (p.category is null or p.category = 'Other');
  select count(*) into v_cats from _cat;

  create temp table _zero on commit drop as
  select p.sku, p.product, p.available
    from products p
   where v_feed >= 1000
     and p.available > 0
     and p.category in ('Apparel','Footwear','Accessories','Bags','Wallets')
     and not exists (select 1 from _s s where s.sku = p.sku);
  select count(*) into v_zero from _zero;

  if p_dry then
    return jsonb_build_object('dry', true, 'feed_skus', v_feed, 'stock_updated', v_stock, 'prices_updated', v_prices,
      'compare_at_updated', v_compare, 'added', v_added, 'categorised', v_cats, 'zeroed', v_zero,
      'zero_sample', (select coalesce(jsonb_agg(t), '[]') from (select * from _zero order by available desc limit 25) t));
  end if;

  update products p set available = s.available, updated_at = now()
    from _s s where p.sku = s.sku and p.available is distinct from s.available;

  insert into product_price_log (sku, product, old_rsp, new_rsp, source)
    select sku, product, old_rsp, new_rsp, 'shopify_sync' from _price;
  update products p set rsp = c.new_rsp, updated_at = now() from _price c where p.sku = c.sku;

  update products p set compare_at = c.compare_at from _ca c where p.sku = c.sku;

  insert into products (sku, product, category, subcat, rsp, available, compare_at, updated_at)
    select sku, product, category, null, rsp, available, compare_at, now() from _new
    on conflict (sku) do nothing;
  insert into product_price_log (sku, product, old_rsp, new_rsp, source)
    select sku, product, null, rsp, 'shopify_new' from _new;

  update products p set category = c.category, updated_at = now() from _cat c where p.sku = c.sku;

  update products p set available = 0, updated_at = now() from _zero z where p.sku = z.sku;

  return jsonb_build_object('dry', false, 'stock_updated', v_stock, 'prices_updated', v_prices,
    'compare_at_updated', v_compare, 'added', v_added, 'categorised', v_cats, 'zeroed', v_zero);
end $function$;
