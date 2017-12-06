from typing import Union

from mediawords.db import DatabaseHandler
from mediawords.util.log import create_logger
from mediawords.util.perl import decode_object_from_bytes_if_needed
from mediawords.util.sql import sql_now

log = create_logger(__name__)


def is_new(db: DatabaseHandler, story: dict) -> bool:
    """Return true if this story should be considered new for the given media source.

    A story is new if no story with the same url or guid exists in the same media
    source and if no story exists with the same title in the same media source in
    the same calendar day."""

    story = decode_object_from_bytes_if_needed(story)

    if story['title'] == '(no title)':
        return False

    db_story = db.query("""
        SELECT *
        FROM stories
        WHERE guid = %(guid)s
          AND media_id = %(media_id)s
    """, {
        'guid': story['guid'],
        'media_id': int(story['media_id'])
    }).hash()

    if db_story is not None:
        return False

    db_story = db.query("""
        SELECT 1
        FROM stories
        WHERE md5(title) = md5(%(story_title)s)
          AND media_id = %(media_id)s
          
          -- We do the goofy " + interval '1 second'" to force postgres to use the stories_title_hash index
          AND date_trunc('day', publish_date) + INTERVAL '1 second' =
              date_trunc('day', %(publish_date)s::date) + INTERVAL '1 second'
              
        -- FIXME why "FOR UPDATE"?
        FOR UPDATE
    """, {
        'story_title': story['title'],
        'media_id': int(story['media_id']),
        'publish_date': story['publish_date'],
    }).hash()

    if db_story is not None:
        return False

    return True


def add_story(db: DatabaseHandler, story: dict, feeds_id: int, skip_checking_if_new: bool = False) -> Union[dict, None]:
    """If the story is new, add story to the database with the feed of the download as story feed."""

    story = decode_object_from_bytes_if_needed(story)

    if isinstance(feeds_id, bytes):
        feeds_id = int(feeds_id)

    feeds_id = int(feeds_id)
    skip_checking_if_new = bool(skip_checking_if_new)

    db.begin()

    db.query("LOCK TABLE stories IN ROW EXCLUSIVE MODE")

    if not skip_checking_if_new:
        if not is_new(db=db, story=story):
            log.info("Story %s is not new." % story['url'])
            db.commit()
            return None

    medium = db.find_by_id(table='media', object_id=story['media_id'])

    if story.get('full_text_rss', None) is None:
        full_text_rss = medium.get('full_text_rss', False)

        story_description = story.get('description', '')
        if len(story_description) == 0:
            full_text_rss = False

        story['full_text_rss'] = full_text_rss

    story = db.query("""
        INSERT INTO stories (
            media_id, url, guid, title, description, publish_date, collect_date, full_text_rss, language
        ) VALUES (
            %(media_id)s,
            %(url)s,
            %(guid)s,
            %(title)s,
            %(description)s,
            %(publish_date)s,
            %(collect_date)s,
            %(full_text_rss)s,
            %(language)s
        )
        ON CONFLICT (guid, media_id) DO -- "stories_guid" constraint
            -- Have to UPDATE for RETURNING to return something
            UPDATE SET guid = EXCLUDED.guid
        RETURNING *
    """, {
        'media_id': int(story['media_id']),
        'url': story['url'],
        'guid': story['guid'],
        'title': story['title'],
        'description': story.get('description', None),
        'publish_date': story['publish_date'],
        'collect_date': story.get('collect_date', sql_now()),
        'full_text_rss': bool(story['full_text_rss']),
        'language': story.get('language', None),
    }).hash()

    db.find_or_create(table='feeds_stories_map', insert_hash={
        'stories_id': int(story['stories_id']),
        'feeds_id': int(feeds_id),
    })

    db.commit()

    return story
