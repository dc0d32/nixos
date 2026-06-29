{
  description = "Data + web-data science: duckdb/polars/pandas/arrow + scraping/crawl (httpx, scrapy, trafilatura, warcio)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      forEachSupportedSystem =
        f: nixpkgs.lib.genAttrs supportedSystems (system: f { pkgs = import nixpkgs { inherit system; }; });
    in
    {
      devShells = forEachSupportedSystem (
        { pkgs }:
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              python3
              uv # `uv add polars pandas pyarrow scrapy trafilatura warcio selectolax`
              ruff
              duckdb # in-process SQL over CSV/JSON/Parquet
            ];
            LD_LIBRARY_PATH = nixpkgs.lib.makeLibraryPath (with pkgs; [ stdenv.cc.cc.lib zlib ]);
            env.UV_PYTHON = "${pkgs.python3}/bin/python";
            shellHook = ''
              echo "datasci shell — uv add polars pandas pyarrow jupyter httpx scrapy trafilatura warcio selectolax"
            '';
          };
        }
      );
    };
}
