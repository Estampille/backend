import os
import tempfile
from unittest import TestCase

import pytest

from podcast_fetch_episode.config import PodcastFetchEpisodeConfig
from podcast_fetch_episode.exceptions import McPodcastMisconfiguredGCSException

from podcast_fetch_episode.gcs_store import GCSStore

from .config_random_gcs_prefix import RandomPathPrefixConfig


class TestGCSStore(TestCase):

    def test_remote_path(self):

        # Empty object ID
        with pytest.raises(McPodcastMisconfiguredGCSException):
            GCSStore._remote_path(path_prefix='', object_id='')

        assert GCSStore._remote_path(path_prefix='', object_id='a') == 'a'
        assert GCSStore._remote_path(path_prefix='', object_id='/a') == 'a'
        assert GCSStore._remote_path(path_prefix='/', object_id='a') == 'a'
        assert GCSStore._remote_path(path_prefix='/', object_id='/a') == 'a'

        # GCS doesn't like double slashes
        assert GCSStore._remote_path(path_prefix='//', object_id='a') == 'a'
        assert GCSStore._remote_path(path_prefix='//', object_id='/a') == 'a'
        assert GCSStore._remote_path(path_prefix='//', object_id='//a') == 'a'
        assert GCSStore._remote_path(path_prefix='//', object_id='//a') == 'a'

        assert GCSStore._remote_path(path_prefix='//', object_id='//a///b//c') == 'a/b/c'

        assert GCSStore._remote_path(path_prefix='//', object_id='//a///b//../b/c') == 'a/b/c'

    def test_object_uri(self):
        gcs = GCSStore()

        # Empty object ID
        with pytest.raises(McPodcastMisconfiguredGCSException):
            gcs.object_uri(object_id='')

        class NoPathPrefixConfig(PodcastFetchEpisodeConfig):

            @staticmethod
            def gc_storage_path_prefix() -> str:
                return ''

        config = NoPathPrefixConfig()
        gcs = GCSStore(config=config)
        assert gcs.object_uri(object_id='a') == f'gs://{config.gc_storage_bucket_name()}/a'

        class MultiPathPrefixConfig(PodcastFetchEpisodeConfig):

            @staticmethod
            def gc_storage_path_prefix() -> str:
                return '//foo/bar//'

        config = MultiPathPrefixConfig()
        gcs = GCSStore(config=config)
        assert gcs.object_uri(object_id='a') == f'gs://{config.gc_storage_bucket_name()}/foo/bar/a'

    def test_store_exists_delete(self):
        config = RandomPathPrefixConfig()
        gcs = GCSStore(config=config)

        object_id = 'test'
        assert gcs.object_exists(object_id=object_id) is False

        mock_data = os.urandom(1024 * 10)
        temp_file = os.path.join(tempfile.mkdtemp('test'), 'test')
        with open(temp_file, mode='wb') as f:
            f.write(mock_data)

        gcs.store_object(local_file_path=temp_file, object_id=object_id)
        assert gcs.object_exists(object_id=object_id) is True

        # Try storing twice
        gcs.store_object(local_file_path=temp_file, object_id=object_id)
        assert gcs.object_exists(object_id=object_id) is True

        gcs.delete_object(object_id=object_id)
        assert gcs.object_exists(object_id=object_id) is False

        # Try deleting nonexistent object
        gcs.delete_object(object_id='does_not_exist')
