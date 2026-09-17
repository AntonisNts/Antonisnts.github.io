-- ===========================================================================
--  SHOP MODULE — item photographs
--  ---------------------------------------------------------------------------
--  Part of the shop module. Storage policies only: no table is created and no
--  table is altered. shop_items.image_url already exists and is already a URL;
--  what changes is where the URL comes from -- a photograph the school takes,
--  uploaded here, rather than a link they had to find somewhere else and paste.
--
--  BEFORE RUNNING THIS: create the bucket in the dashboard.
--    Storage → New bucket → name: shop-images → PUBLIC → Create.
--  Then run this file.
--
--  Public is right, and is the same choice announcement-images made. A parent
--  browsing the shop is authenticated, but the <img> tag that fetches the
--  picture is not -- the browser sends no session with it. A private bucket
--  would mean signing every URL and re-signing it when it expired, for a
--  photograph of a jumper. Nothing here is a document; it is a picture of
--  something already for sale to the school's own families.
--
--  Writing is not public. A file may only be written into the folder named
--  after a business the caller OWNS, which is what stops one school putting
--  images into another's folder -- or replacing the picture on their jumper.
-- ===========================================================================

drop policy if exists shop_images_public_read on storage.objects;
create policy shop_images_public_read on storage.objects
  for select using (bucket_id = 'shop-images');

drop policy if exists shop_images_owner_write on storage.objects;
create policy shop_images_owner_write on storage.objects
  for insert to authenticated with check (
    bucket_id = 'shop-images'
    and (storage.foldername(name))[1] in
        (select id::text from public.businesses where owner_id = auth.uid()));

drop policy if exists shop_images_owner_update on storage.objects;
create policy shop_images_owner_update on storage.objects
  for update to authenticated using (
    bucket_id = 'shop-images'
    and (storage.foldername(name))[1] in
        (select id::text from public.businesses where owner_id = auth.uid()))
  with check (
    bucket_id = 'shop-images'
    and (storage.foldername(name))[1] in
        (select id::text from public.businesses where owner_id = auth.uid()));

drop policy if exists shop_images_owner_delete on storage.objects;
create policy shop_images_owner_delete on storage.objects
  for delete to authenticated using (
    bucket_id = 'shop-images'
    and (storage.foldername(name))[1] in
        (select id::text from public.businesses where owner_id = auth.uid()));


-- ===========================================================================
--  REMOVING THIS
--
--    drop policy if exists shop_images_owner_delete on storage.objects;
--    drop policy if exists shop_images_owner_update on storage.objects;
--    drop policy if exists shop_images_owner_write  on storage.objects;
--    drop policy if exists shop_images_public_read  on storage.objects;
--
--  and delete the shop-images bucket in the dashboard. Nothing else in the
--  shop module depends on this file: without it, image_url simply stays empty
--  and items show without a picture, exactly as they did before.
-- ===========================================================================
