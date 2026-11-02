-- ====== MI STOCK: permitir "agregar stock" (ingreso de mercadería) ======
-- No borra nada. Se puede ejecutar más de una vez.

alter table public.movimientos drop constraint if exists movimientos_tipo_check;
alter table public.movimientos add constraint movimientos_tipo_check
  check (tipo in ('venta','ajuste','ingreso'));

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

revoke all on function public.agregar_stock(uuid,int) from public, anon;
grant execute on function public.agregar_stock(uuid,int) to authenticated;
