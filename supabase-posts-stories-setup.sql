-- Run once in the Supabase SQL Editor for the project used by index.html.
-- Public buckets are required because the page renders getPublicUrl() links.

CREATE OR REPLACE FUNCTION public.handle_new_kundeconnect_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.profiles (id, full_name, avatar_url)
  VALUES (
    NEW.id,
    COALESCE(
      NEW.raw_user_meta_data ->> 'full_name',
      NULLIF(concat_ws(' ', NEW.raw_user_meta_data ->> 'prenom', NEW.raw_user_meta_data ->> 'nom'), '')
    ),
    COALESCE(NEW.raw_user_meta_data ->> 'avatar_url', NEW.raw_user_meta_data ->> 'picture')
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.handle_new_kundeconnect_user() FROM PUBLIC, anon, authenticated;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgname = 'kundeconnect_create_profile_after_signup'
      AND tgrelid = 'auth.users'::regclass
      AND NOT tgisinternal
  ) THEN
    CREATE TRIGGER kundeconnect_create_profile_after_signup
      AFTER INSERT ON auth.users
      FOR EACH ROW EXECUTE FUNCTION public.handle_new_kundeconnect_user();
  END IF;
END;
$$;

INSERT INTO public.profiles (id, full_name, avatar_url)
SELECT
  users.id,
  COALESCE(
    users.raw_user_meta_data ->> 'full_name',
    NULLIF(concat_ws(' ', users.raw_user_meta_data ->> 'prenom', users.raw_user_meta_data ->> 'nom'), '')
  ),
  COALESCE(users.raw_user_meta_data ->> 'avatar_url', users.raw_user_meta_data ->> 'picture')
FROM auth.users AS users
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.posts
  ADD COLUMN IF NOT EXISTS mood text,
  ADD COLUMN IF NOT EXISTS media_url text;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES
  ('media', 'media', true, 52428800, ARRAY['image/*', 'video/*']::text[]),
  ('stories', 'stories', true, 52428800, ARRAY['image/*', 'video/*']::text[])
ON CONFLICT (id) DO UPDATE SET
  public = EXCLUDED.public,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

ALTER TABLE public.posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stories ENABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT ON TABLE public.posts, public.stories TO authenticated;

DROP POLICY IF EXISTS kundeconnect_posts_read ON public.posts;
CREATE POLICY kundeconnect_posts_read
  ON public.posts FOR SELECT TO authenticated
  USING (true);

DROP POLICY IF EXISTS kundeconnect_posts_insert_own ON public.posts;
CREATE POLICY kundeconnect_posts_insert_own
  ON public.posts FOR INSERT TO authenticated
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS kundeconnect_stories_read ON public.stories;
CREATE POLICY kundeconnect_stories_read
  ON public.stories FOR SELECT TO authenticated
  USING (true);

DROP POLICY IF EXISTS kundeconnect_stories_insert_own ON public.stories;
CREATE POLICY kundeconnect_stories_insert_own
  ON public.stories FOR INSERT TO authenticated
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS kundeconnect_public_media_read ON storage.objects;
CREATE POLICY kundeconnect_public_media_read
  ON storage.objects FOR SELECT TO anon, authenticated
  USING (bucket_id IN ('media', 'stories'));

DROP POLICY IF EXISTS kundeconnect_media_insert_own ON storage.objects;
CREATE POLICY kundeconnect_media_insert_own
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (
    (
      bucket_id = 'stories'
      AND (storage.foldername(name))[1] = (SELECT auth.uid()::text)
    )
    OR
    (
      bucket_id = 'media'
      AND (storage.foldername(name))[1] = 'posts'
      AND (storage.foldername(name))[2] = (SELECT auth.uid()::text)
    )
  );

DROP POLICY IF EXISTS kundeconnect_media_delete_own ON storage.objects;
CREATE POLICY kundeconnect_media_delete_own
  ON storage.objects FOR DELETE TO authenticated
  USING (
    (
      bucket_id = 'stories'
      AND (storage.foldername(name))[1] = (SELECT auth.uid()::text)
    )
    OR
    (
      bucket_id = 'media'
      AND (storage.foldername(name))[1] = 'posts'
      AND (storage.foldername(name))[2] = (SELECT auth.uid()::text)
    )
  );