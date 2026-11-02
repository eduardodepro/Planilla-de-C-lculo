-- ====== MI STOCK (varios comercios): configuración de Supabase ======
-- ATENCIÓN: borra los datos de prueba anteriores (productos, perfiles, historial).

drop trigger if exists al_crear_usuario on auth.users;
drop table if exists public.movimientos, public.products, public.settings, public.profiles, public.negocios cascade;
drop function if exists public.nuevo_usuario();
drop function if exists public.es_miembro();
drop function if exists public.es_dueno();
drop function if exists public.registrar_venta(uuid,int);
drop function if exists public.ajustar_stock(uuid,int);

-- 1) Tablas
create table public.negocios (
  id uuid primary key default gen_random_uuid(),
  nombre text not null,
  codigo text not null unique default upper(substr(md5(random()::text || clock_timestamp()::text),1,8)),
  ganancia_general numeric not null default 30,
  created_at timestamptz not null default now()
);

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  negocio_id uuid not null references public.negocios(id) on delete cascade,
  nombre text not null,
  rol text not null check (rol in ('dueno','empleado'))
);

create or replace function public.mi_negocio() returns uuid
language sql security definer stable set search_path = public as $$
  select negocio_id from public.profiles where id = auth.uid()
$$;

create or replace function public.es_dueno() returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and rol = 'dueno')
$$;

create table public.products (
  id uuid primary key default gen_random_uuid(),
  negocio_id uuid not null default public.mi_negocio() references public.negocios(id) on delete cascade,
  nombre text not null,
  unidades_pack int not null default 1 check (unidades_pack >= 1),
  precio_mayor numeric not null default 0 check (precio_mayor >= 0),
  ganancia numeric check (ganancia >= 0),
  stock int not null default 0 check (stock >= 0),
  stock_min int check (stock_min >= 0),
  created_at timestamptz not null default now()
);

create table public.movimientos (
  id bigint generated always as identity primary key,
  negocio_id uuid not null references public.negocios(id) on delete cascade,
  producto_id uuid references public.products(id) on delete set null,
  producto_nombre text not null,
  tipo text not null check (tipo in ('venta','ajuste','ingreso')),
  cantidad int not null,
  stock_antes int not null,
  stock_despues int not null,
  usuario_id uuid,
  usuario_nombre text,
  created_at timestamptz not null default now()
);

-- 2) Crear un negocio nuevo / unirse con un código
create or replace function public.crear_negocio(p_negocio text, p_nombre text) returns void
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'Sin sesión'; end if;
  if exists (select 1 from public.profiles where id = auth.uid()) then raise exception 'Ya pertenecés a un negocio'; end if;
  if length(trim(coalesce(p_negocio,''))) < 2 or length(trim(coalesce(p_nombre,''))) < 1 then
    raise exception 'Completá el nombre del negocio y el tuyo';
  end if;
  insert into public.negocios (nombre) values (left(trim(p_negocio),80)) returning id into v_id;
  insert into public.profiles (id, negocio_id, nombre, rol) values (auth.uid(), v_id, left(trim(p_nombre),60), 'dueno');
end $$;

create or replace function public.unirse_negocio(p_codigo text, p_nombre text) returns void
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'Sin sesión'; end if;
  if exists (select 1 from public.profiles where id = auth.uid()) then raise exception 'Ya pertenecés a un negocio'; end if;
  if length(trim(coalesce(p_nombre,''))) < 1 then raise exception 'Poné tu nombre'; end if;
  select id into v_id from public.negocios where codigo = upper(trim(p_codigo));
  if v_id is null then raise exception 'Código inválido'; end if;
  insert into public.profiles (id, negocio_id, nombre, rol) values (auth.uid(), v_id, left(trim(p_nombre),60), 'empleado');
end $$;

-- 3) Gestión de empleados (solo dueño)
create or replace function public.mi_codigo() returns text
language plpgsql security definer set search_path = public as $$
declare v text;
begin
  if not public.es_dueno() then raise exception 'Solo el dueño'; end if;
  select codigo into v from public.negocios where id = public.mi_negocio();
  return v;
end $$;

create or replace function public.regenerar_codigo() returns text
language plpgsql security definer set search_path = public as $$
declare v text;
begin
  if not public.es_dueno() then raise exception 'Solo el dueño'; end if;
  update public.negocios set codigo = upper(substr(md5(random()::text || clock_timestamp()::text),1,8))
  where id = public.mi_negocio() returning codigo into v;
  return v;
end $$;

create or replace function public.quitar_empleado(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.es_dueno() then raise exception 'Solo el dueño'; end if;
  delete from public.profiles where id = p_id and negocio_id = public.mi_negocio() and rol = 'empleado';
end $$;

-- 4) Ventas y ajustes de stock
create or replace function public.registrar_venta(p_producto uuid, p_unidades int) returns int
language plpgsql security definer set search_path = public as $$
declare v_prod public.products; v_nom text;
begin
  if public.mi_negocio() is null then raise exception 'Sin permiso'; end if;
  if p_unidades is null or p_unidades <= 0 then raise exception 'Cantidad inválida'; end if;
  select * into v_prod from public.products where id = p_producto and negocio_id = public.mi_negocio() for update;
  if not found then raise exception 'Producto no encontrado'; end if;
  if v_prod.stock < p_unidades then raise exception 'No alcanza el stock (hay % unidades)', v_prod.stock; end if;
  update public.products set stock = stock - p_unidades where id = p_producto;
  select nombre into v_nom from public.profiles where id = auth.uid();
  insert into public.movimientos (negocio_id, producto_id, producto_nombre, tipo, cantidad, stock_antes, stock_despues, usuario_id, usuario_nombre)
  values (v_prod.negocio_id, p_producto, v_prod.nombre, 'venta', -p_unidades, v_prod.stock, v_prod.stock - p_unidades, auth.uid(), v_nom);
  return v_prod.stock - p_unidades;
end $$;

create or replace function public.ajustar_stock(p_producto uuid, p_stock int) returns int
language plpgsql security definer set search_path = public as $$
declare v_prod public.products; v_nom text;
begin
  if not public.es_dueno() then raise exception 'Solo el dueño puede ajustar el stock'; end if;
  if p_stock is null or p_stock < 0 then raise exception 'Stock inválido'; end if;
  select * into v_prod from public.products where id = p_producto and negocio_id = public.mi_negocio() for update;
  if not found then raise exception 'Producto no encontrado'; end if;
  update public.products set stock = p_stock where id = p_producto;
  select nombre into v_nom from public.profiles where id = auth.uid();
  insert into public.movimientos (negocio_id, producto_id, producto_nombre, tipo, cantidad, stock_antes, stock_despues, usuario_id, usuario_nombre)
  values (v_prod.negocio_id, p_producto, v_prod.nombre, 'ajuste', p_stock - v_prod.stock, v_prod.stock, p_stock, auth.uid(), v_nom);
  return p_stock;
end $$;

-- 4b) Agregar stock (llegó mercadería)
create or replace function public.agregar_stock(p_producto uuid, p_unidades int) returns int
language plpgsql security definer set search_path = public as $$
declare v_prod public.products; v_nom text;
begin
  if public.mi_negocio() is null then raise exception 'Sin permiso'; end if;
  if p_unidades is null or p_unidades <= 0 then raise exception 'Cantidad inválida'; end if;
  select * into v_prod from public.products where id = p_producto and negocio_id = public.mi_negocio() for update;
  if not found then raise exception 'Producto no encontrado'; end if;
  update public.products set stock = stock + p_unidades where id = p_producto;
  select nombre into v_nom from public.profiles where id = auth.uid();
  insert into public.movimientos (negocio_id, producto_id, producto_nombre, tipo, cantidad, stock_antes, stock_despues, usuario_id, usuario_nombre)
  values (v_prod.negocio_id, p_producto, v_prod.nombre, 'ingreso', p_unidades, v_prod.stock, v_prod.stock + p_unidades, auth.uid(), v_nom);
  return v_prod.stock + p_unidades;
end $$;

revoke all on function public.mi_negocio(), public.es_dueno(), public.crear_negocio(text,text), public.unirse_negocio(text,text),
  public.mi_codigo(), public.regenerar_codigo(), public.quitar_empleado(uuid), public.registrar_venta(uuid,int), public.ajustar_stock(uuid,int), public.agregar_stock(uuid,int)
  from public, anon;
grant execute on function public.mi_negocio(), public.es_dueno(), public.crear_negocio(text,text), public.unirse_negocio(text,text),
  public.mi_codigo(), public.regenerar_codigo(), public.quitar_empleado(uuid), public.registrar_venta(uuid,int), public.ajustar_stock(uuid,int), public.agregar_stock(uuid,int)
  to authenticated;

-- 5) Seguridad: cada negocio ve solo lo suyo
alter table public.negocios enable row level security;
alter table public.profiles enable row level security;
alter table public.products enable row level security;
alter table public.movimientos enable row level security;

grant usage on schema public to authenticated;
grant select (id, nombre, ganancia_general) on public.negocios to authenticated;
grant update (nombre, ganancia_general) on public.negocios to authenticated;
grant select on public.profiles, public.movimientos to authenticated;
grant select, insert, update, delete on public.products to authenticated;

create policy "ver mi negocio" on public.negocios for select to authenticated using (id = public.mi_negocio());
create policy "dueno edita negocio" on public.negocios for update to authenticated
  using (id = public.mi_negocio() and public.es_dueno()) with check (id = public.mi_negocio() and public.es_dueno());
create policy "ver perfiles del negocio" on public.profiles for select to authenticated using (negocio_id = public.mi_negocio());
create policy "ver productos" on public.products for select to authenticated using (negocio_id = public.mi_negocio());
create policy "dueno agrega productos" on public.products for insert to authenticated
  with check (negocio_id = public.mi_negocio() and public.es_dueno());
create policy "dueno edita productos" on public.products for update to authenticated
  using (negocio_id = public.mi_negocio() and public.es_dueno()) with check (negocio_id = public.mi_negocio() and public.es_dueno());
create policy "dueno borra productos" on public.products for delete to authenticated
  using (negocio_id = public.mi_negocio() and public.es_dueno());
create policy "ver historial" on public.movimientos for select to authenticated using (negocio_id = public.mi_negocio());
