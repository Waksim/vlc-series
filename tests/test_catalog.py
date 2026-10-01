import copy
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import sofa
from tools.frames import parse_times

class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.base=Path(self.temp.name);self.profile=self.base/'profile'
    def tearDown(self):self.temp.cleanup()
    def media(self,show,name):
        path=self.base/show/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(b'fixture');return path
    def test_patterns(self):
        for name,folder,expected in [('Show.S02E03.mkv',None,(2,3)),('Show.S02.E03.mkv',None,(2,3)),('Show.2x03.mp4',None,(2,3)),('Episode 07.mp4',3,(3,7)),('Серия 8.mkv',2,(2,8)),('09 - Name.mkv',1,(1,9)),('Trailer.mp4',2,None),('S01E00.mkv',None,None)]:
            with self.subTest(name=name):self.assertEqual(sofa.episode_number(name,folder),expected)
    def test_duplicate_does_not_silently_pick_file(self):
        self.media('show','One.S01E01.mkv');self.media('show','Other.S01E01.mp4')
        with self.assertRaises(ValueError):sofa.add_series(self.profile,[self.base/'show'])
        self.assertFalse((self.profile/'libraries.json').exists())
    @patch('sofa.probe',return_value=100)
    def test_series_identity_progress_and_reindex(self,_):
        self.media('one','One.S01E01.mp4');self.media('two','Two.S01E01.mp4')
        sofa.atomic_json(self.profile/'progress.json',{'version':1,'episodes':{'old':{'resume':45}}})
        original=(self.profile/'progress.json').read_bytes()
        one=sofa.add_series(self.profile,[self.base/'one'])[0];two=sofa.add_series(self.profile,[self.base/'two'])[0]
        self.assertNotEqual(one['id'],two['id'])
        again=sofa.add_series(self.profile,[self.base/'one'],title='New title')[0]
        self.assertEqual(one['id'],again['id']);self.assertEqual((self.profile/'progress.json').read_bytes(),original)
        self.assertEqual(len(sofa.registry(self.profile)['libraries']),2)
        self.assertEqual(len(sofa.read_json(self.profile/'library-cache.json')['libraries']),2)
    @patch('sofa.probe',return_value=100)
    def test_legacy_ids_preserved(self,_):
        self.media('one','One.S01E01.mp4');self.media('two','Two.S01E01.mp4')
        sofa.atomic_json(self.profile/'settings.json',{'libraryRoot':str(self.base/'one'),'libraryTitle':'Original'})
        sofa.add_series(self.profile,[self.base/'two'])
        first=sofa.registry(self.profile)['libraries'][0]
        self.assertEqual(first['id'],'legacy');self.assertTrue(first['legacy'])
    def test_unrecognized_and_symlink_files(self):
        self.media('one','Season 02/Episode 03.mp4');self.media('one','Trailer.mp4')
        (self.base/'one'/'Outside.S01E01.mp4').symlink_to(self.media('outside','X.S01E01.mp4'))
        inventory=sofa.scan(self.base/'one')
        self.assertEqual([e['key'] for e in inventory['episodes']],['s02e03'])
        self.assertEqual(inventory['ignored'],['Trailer.mp4'])
    def test_corrupt_registry_is_not_replaced(self):
        self.profile.mkdir();p=self.profile/'libraries.json';p.write_text('{broken')
        with self.assertRaises(ValueError):sofa.registry(self.profile)
        self.assertEqual(p.read_text(),'{broken')
    def test_marker_binding_and_optional_segments(self):
        entry={'file':'Season 01/Show.S01E01.mp4','size':20,'mtime':123,'duration':100}
        marker={**entry,'verified':True,'intro':{'start':10,'skipTo':27,'finish':30},'credits':{'start':90,'nextAt':92}}
        self.assertTrue(sofa.valid_marker(marker,entry))
        for k,v in [('file','elsewhere'),('size',21),('mtime',124),('duration',110),('verified',False)]:
            bad=copy.deepcopy(marker);bad[k]=v;self.assertFalse(sofa.valid_marker(bad,entry))
        bad=copy.deepcopy(marker);bad['intro']['skipTo']=float('nan');self.assertFalse(sofa.valid_marker(bad,entry))
        marker['intro']=None;self.assertTrue(sofa.valid_marker(marker,entry))
        marker['credits']=None;self.assertTrue(sofa.valid_marker(marker,entry))
    def test_frame_ranges_are_bounded(self):
        self.assertEqual(parse_times('0:20:5,25',30),[0,5,10,15,25])
        for spec in ['0:500:1','0:10:0','nan','30','-1']:
            with self.subTest(spec=spec),self.assertRaises(ValueError):parse_times(spec,30)

if __name__=='__main__':unittest.main()
