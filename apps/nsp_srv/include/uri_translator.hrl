-record(ut_word, {word      :: string(),    %% Word in turkish
                  lang      :: string(),    %% tr
                  english   :: string()}).  %% Word in english
-record(ut_translation, {source :: {string(), string()},    %% {"tr", Word in english}
                         word   :: string()}).              %% Word in turkish

%%NOTE:
%%  For each language in which system pages may be translated, developers should add the whole new
%%  list of page translations, each of which should consist of a tuple in the form
%%      { word_in_english, language, word_in_language }
%%  Then, after compiling the zealot project, developer should run zealot_db_update:update_db().
%%  Turkish and spanish translations provided as an example.
-define(URI_DICTIONARY, [%% Turkish ----------------------------------------------------------------
                         {"access-denied", "tr", "erisim-engellendi"},
                         {"account", "tr", "hesap"},
                         {"profile", "tr", "profilim"},
                         {"stats", "tr", "istatistikler"},
                         {"admin", "tr", "yonetim"},
                         {"avatar", "tr", "avatar"},
                         {"client", "tr", "oyun"},
                         {"create-game", "tr", "oyun-yarat"},
                         {"dashboard", "tr", "panel"},
                         {"price-table", "tr", "fiyat-tablosu"},
                         {"friends", "tr", "arkadaslar"},
                         {"get-file", "tr", "dosya"},
                         {"gifts", "tr", "hediyeler"},
                         {"groups", "tr", "gruplar"},
                         {"invite", "tr", "davet-et"},
                         {"join-game", "tr", "oyuna-baglan"},
                         {"login", "tr", "giris"},
                         {"main", "tr", "ana-sayfa"},
                         {"matchmaker", "tr", "oyun-kuran"},
                         {"okey", "tr", "okey"},
                         {"tavla", "tr", "tavla"},
                         {"privacy", "tr", "gizlilik"},
                         {"social", "tr", "sosyal"},
                         {"terms", "tr", "kullanim-sartlari"},
                         {"tournaments", "tr", "turnuvalar"},
                         {"verify", "tr", "onay"},
                         {"view", "tr", "bak"},
                         {"group", "tr", "gruba"},
                         {"view-group", "tr", "gruba-bak"},
                         {"view-table", "tr", "masaya-bak"},
                         {"view-user", "tr", "oyuncu-goruntule"},
                         {"contact", "tr", "iletisim"},
                         {"id", "tr", "id"},
                         {"csid", "tr", "csid"},
                         {"wall", "tr", "wall"},
                         {"info-gifts", "tr", "hediyeler-bilgi"},
                         {"info-tournaments", "tr", "turnuvalar-bilgi"},
                         {"info-social", "tr", "sosyal-bilgi"},
                         {"info-matchmaker", "tr", "oyun-kuran-bilgi"},
                         {"info-why", "tr", "neden-bilgi"},
                         {"success", "tr", "basarili"},
                         {"fail", "tr", "basarisiz"},
                         %% Spanish ----------------------------------------------------------------
                         {"access-denied", "es", "acceso-denegado"},
                         {"account", "es", "cuenta"},
                         {"admin", "es", "administracion"},
                         {"avatar", "es", "imagen"},
                         {"client", "es", "cliente"},
                         {"create-game", "es", "crear-partido"},
                         {"dashboard", "es", "panel-principal"},
                         {"friends", "es", "amigos"},
                         {"get-file", "es", "archivo"},
                         {"gifts", "es", "regalos"},
                         {"groups", "es", "grupos"},
                         {"invite", "es", "invitar"},
                         {"join-game", "es", "ingresar-en-partido"},
                         {"login", "es", "ingresar"},
                         {"main", "es", "principal"},
                         {"matchmaker", "es", "arma-partido"},
                         {"okey", "es", "okey"},
                         {"privacy", "es", "privacidad"},
                         {"social", "es", "social"},
                         {"terms", "es", "terminos"},
                         {"tournaments", "es", "torneos"},
                         {"verify", "es", "verificar"},
                         {"view", "es", "ver"},
                         {"group", "es", "grupo"},
                         {"view-group", "es", "ver-grupo"},
                         {"view-table", "es", "ver-tabla"},
                         {"view-user", "es", "ver-usuario"},
                         {"contact", "es", "contacto"},
                         {"id", "es", "id"},
                         {"csid", "es", "csid"},
                         {"info-gifts", "es", "info-regalos"},
                         {"info-tournaments", "es", "info-torneos"},
                         {"info-social", "es", "info-social"},
                         {"info-matchmaker", "es", "info-arma-partido"},
                         {"info-why", "es", "info-por-que"},
                         {"success", "es", "exito"},
                         {"fail", "es", "suspender"}
                         ]).
