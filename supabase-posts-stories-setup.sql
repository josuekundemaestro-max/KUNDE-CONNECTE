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

CREATE TABLE IF NOT EXISTS public.post_likes (
  post_id uuid NOT NULL REFERENCES public.posts(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  PRIMARY KEY (post_id, user_id)
);

CREATE TABLE IF NOT EXISTS public.post_comments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id uuid NOT NULL REFERENCES public.posts(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  content text NOT NULL CHECK (char_length(trim(content)) BETWEEN 1 AND 1000),
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now())
);

ALTER TABLE public.post_comments
  ADD COLUMN IF NOT EXISTS parent_comment_id uuid
  REFERENCES public.post_comments(id) ON DELETE CASCADE;

CREATE TABLE IF NOT EXISTS public.post_shares (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id uuid NOT NULL REFERENCES public.posts(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now())
);

CREATE INDEX IF NOT EXISTS post_likes_post_id_idx ON public.post_likes(post_id);
CREATE INDEX IF NOT EXISTS post_comments_post_created_idx ON public.post_comments(post_id, created_at);
CREATE INDEX IF NOT EXISTS post_comments_parent_created_idx ON public.post_comments(parent_comment_id, created_at);
CREATE INDEX IF NOT EXISTS post_shares_post_id_idx ON public.post_shares(post_id);

ALTER TABLE public.post_likes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.post_comments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.post_shares ENABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT, DELETE ON TABLE public.post_likes TO authenticated;
GRANT SELECT, INSERT, DELETE ON TABLE public.post_comments TO authenticated;
GRANT SELECT, INSERT ON TABLE public.post_shares TO authenticated;

DROP POLICY IF EXISTS kundeconnect_post_likes_read ON public.post_likes;
CREATE POLICY kundeconnect_post_likes_read
  ON public.post_likes FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS kundeconnect_post_likes_insert_own ON public.post_likes;
CREATE POLICY kundeconnect_post_likes_insert_own
  ON public.post_likes FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
DROP POLICY IF EXISTS kundeconnect_post_likes_delete_own ON public.post_likes;
CREATE POLICY kundeconnect_post_likes_delete_own
  ON public.post_likes FOR DELETE TO authenticated USING (auth.uid() = user_id);

DROP POLICY IF EXISTS kundeconnect_post_comments_read ON public.post_comments;
CREATE POLICY kundeconnect_post_comments_read
  ON public.post_comments FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS kundeconnect_post_comments_insert_own ON public.post_comments;
CREATE POLICY kundeconnect_post_comments_insert_own
  ON public.post_comments FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
DROP POLICY IF EXISTS kundeconnect_post_comments_delete_own ON public.post_comments;
CREATE POLICY kundeconnect_post_comments_delete_own
  ON public.post_comments FOR DELETE TO authenticated USING (auth.uid() = user_id);

DROP POLICY IF EXISTS kundeconnect_post_shares_read ON public.post_shares;
CREATE POLICY kundeconnect_post_shares_read
  ON public.post_shares FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS kundeconnect_post_shares_insert_own ON public.post_shares;
CREATE POLICY kundeconnect_post_shares_insert_own
  ON public.post_shares FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);