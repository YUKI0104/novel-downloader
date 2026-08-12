export namespace main {
	
	export class BookInfo {
	    platform: string;
	    bookId: string;
	    title: string;
	    author: string;
	    description: string;
	    chapterCount: number;
	    coverUrl: string;
	    tags: string;
	    isOver: boolean;
	    score: string;
	    words: string;
	    hot: string;
	    rank: string;
	    category: string;
	    characters: string;
	
	    static createFrom(source: any = {}) {
	        return new BookInfo(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.platform = source["platform"];
	        this.bookId = source["bookId"];
	        this.title = source["title"];
	        this.author = source["author"];
	        this.description = source["description"];
	        this.chapterCount = source["chapterCount"];
	        this.coverUrl = source["coverUrl"];
	        this.tags = source["tags"];
	        this.isOver = source["isOver"];
	        this.score = source["score"];
	        this.words = source["words"];
	        this.hot = source["hot"];
	        this.rank = source["rank"];
	        this.category = source["category"];
	        this.characters = source["characters"];
	    }
	}
	export class LibraryItem {
	    name: string;
	    path: string;
	    size: number;
	    ext: string;
	    platform: string;
	    time: string;
	
	    static createFrom(source: any = {}) {
	        return new LibraryItem(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.name = source["name"];
	        this.path = source["path"];
	        this.size = source["size"];
	        this.ext = source["ext"];
	        this.platform = source["platform"];
	        this.time = source["time"];
	    }
	}
	export class RankGenre {
	    name: string;
	    readUrl: string;
	    newUrl: string;
	
	    static createFrom(source: any = {}) {
	        return new RankGenre(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.name = source["name"];
	        this.readUrl = source["readUrl"];
	        this.newUrl = source["newUrl"];
	    }
	}
	export class RankCategory {
	    gender: string;
	    hotUrl: string;
	    genres: RankGenre[];
	
	    static createFrom(source: any = {}) {
	        return new RankCategory(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.gender = source["gender"];
	        this.hotUrl = source["hotUrl"];
	        this.genres = this.convertValues(source["genres"], RankGenre);
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}
	
	export class RankedBook {
	    position: number;
	    platform: string;
	    bookId: string;
	    title: string;
	    author: string;
	    words: string;
	    hot: string;
	    score: string;
	    coverUrl: string;
	
	    static createFrom(source: any = {}) {
	        return new RankedBook(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.position = source["position"];
	        this.platform = source["platform"];
	        this.bookId = source["bookId"];
	        this.title = source["title"];
	        this.author = source["author"];
	        this.words = source["words"];
	        this.hot = source["hot"];
	        this.score = source["score"];
	        this.coverUrl = source["coverUrl"];
	    }
	}
	export class SearchItem {
	    platform: string;
	    bookId: string;
	    title: string;
	    author: string;
	    abstract: string;
	    isOver: boolean;
	    score: string;
	    words: string;
	    hot: string;
	    coverUrl: string;
	
	    static createFrom(source: any = {}) {
	        return new SearchItem(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.platform = source["platform"];
	        this.bookId = source["bookId"];
	        this.title = source["title"];
	        this.author = source["author"];
	        this.abstract = source["abstract"];
	        this.isOver = source["isOver"];
	        this.score = source["score"];
	        this.words = source["words"];
	        this.hot = source["hot"];
	        this.coverUrl = source["coverUrl"];
	    }
	}
	export class Settings {
	    downloadDir: string;
	    format: string;
	    fanqieBin: string;
	
	    static createFrom(source: any = {}) {
	        return new Settings(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.downloadDir = source["downloadDir"];
	        this.format = source["format"];
	        this.fanqieBin = source["fanqieBin"];
	    }
	}

}

