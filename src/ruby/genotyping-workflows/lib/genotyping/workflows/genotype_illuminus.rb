#-- encoding: UTF-8
#
# Copyright (c) 2012 Genome Research Ltd. All rights reserved.
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

module Genotyping::Workflows

  class GenotypeIlluminus < Percolate::Workflow
    include Genotyping
    include Genotyping::Tasks::Metadata
    include Genotyping::Tasks::GenotypeCall
    include Genotyping::Tasks::Simtools
    include Genotyping::Tasks::Illuminus
    include Genotyping::Tasks::Plink
    include Genotyping::Tasks::QualityControl

    description <<-DESC
Collates the normalized intensity values and GenCall genotype calls for the
samples in one named pipeline run. The former are written into a single SIM
format file, the latter into a Plink BED format file. Calls genotypes using
Illuminus and writes them to an additional Plink BED format file.

Requires a populated pipeline database.
    DESC

    usage <<-USAGE
GenotypeIlluminus args

Arguments:

- db_file (String): The SQLite pipeline database file.
- run_name (String): The name of a pipeline run defined in the pipeline database.
- work_dir (String): The working directory, an absolute path.
- other arguments (keys and values):

    - config: <path> of custom pipeline database .ini file. Optional.
    - manifest: <path> of the chip manifest file. Required.
    - gender_method: <string> name of a gender determination method described in
    methods.ini. Optional, defaults to 'Inferred'
    - chunk_size: <integer> number of SNPs to analyse in a single Illuminus job.
    Optional, defaults to 2000.
    - memory: <integer> number of Mb to request for jobs.
    - queue: <normal | long etc.> An LSF queue hint. Optional, defaults to
    'normal'.
    - filterconfig: <path> to .json file with thresholds for prefilter on 
    GenCall QC. Optional; if absent, uses default illuminus thresholds 
    (requires config argument to be specified).
    - nofilter: <boolean> omit the prefilter on GenCall QC. Optional. If true, 
    overrides the filterconfig argument.

e.g.

 library: genotyping
 workflow: Genotyping::Workflows::GenotypeIlluminus
 arguments:
     - /work/my_project/my_analysis.db
     - sample_batch_1
     - /work/my_project/pipeline/
     - config: /work/my_project/pipeline/pipedb.ini
       queue: small
       manifest: /genotyping/manifests/Human670-QuadCustom_v1_A.bpm.csv

Returns:

- boolean.
    USAGE

    #version '0.1.0'

    def run(dbfile, run_name, work_dir, args = {})
      defaults = {}
      args = intern_keys(defaults.merge(args))
      args = ensure_valid_args(args, :config, :manifest, :queue, :memory,
                               :select, :chunk_size, :gender_method,
                               :filterconfig, :nofilter)

      async_defaults = {:memory => 1024}
      async = lsf_args(args, async_defaults, :memory, :queue, :select)

      manifest = args.delete(:manifest) # TODO: find manifest automatically
      chunk_size = args.delete(:chunk_size) || 2000
      gender_method = args.delete(:gender_method)
      gtconfig = args.delete(:config)
      fconfig = args.delete(:filterconfig) || nil
      nofilter = args.delete(:nofilter) || nil

      args.delete(:memory)
      args.delete(:queue)
      args.delete(:select)

      ENV['PERL_INLINE_DIRECTORY'] = self.inline_dir

      work_dir = maybe_work_dir(work_dir)
      log_dir = File.join(work_dir, 'log')
      Dir.mkdir(log_dir) unless File.exist?(log_dir)
      args = {:work_dir => work_dir,
              :log_dir => log_dir}.merge(args)
      maybe_version_log(log_dir)

      run_name = run_name.to_s;
      gcsjname = run_name + '.gencall.sample.json'
      sjname = run_name + '.illuminus.sample.json'
      njname = run_name + '.snp.json'
      cjname = run_name + '.chr.json'
      smname = run_name + '.illuminus.sim'
      gciname = run_name + '.gencall.imajor.bed'
      gcsname = run_name + '.gencall.smajor.bed'
      ilname = run_name + '.illuminus.bed'

      gcsjson = sample_intensities(dbfile, run_name, gcsjname, args) 
      gcifile, * = gtc_to_bed(gcsjson, manifest, gciname, args, async)
      gcsfile = transpose_bed(gcifile, gcsname, args, async)

      ## run gencall QC to apply gencall CR filter and find genders
      gcqcargs = {:run => run_name}.merge(args)
      gcqcdir = File.join(work_dir, 'gencall_qc')
      gcquality = quality_control(dbfile, gcsfile, gcqcdir, gcqcargs, 
                                  async, true)

      ## apply filtering to pipeline DB, if required
      filtered = nil
      if gcquality
        if nofilter
          filtered = true
        else
          # maf/het and intensity metrics are not calculated (or required)
          gcqcjson = File.join(gcqcdir, 'supplementary', 'qc_results.json')
          if fconfig then fargs = {:thresholds => fconfig}.merge(args)
          else fargs = {:illuminus => true}.merge(args)
          end
          filtered = filter_samples(gcqcjson, dbfile, fargs)
        end
      end

      ## use post-filter pipeline DB to generate sample JSON and .sim file
      ## also parse manifest
      siargs = {:config => gtconfig,
        :gender_method => gender_method}.merge(args)
      smfile = nil
      cjson = nil
      if filtered
        sjson = sample_intensities(dbfile, run_name, sjname, siargs)
        smargs = {:normalize => true }.merge(args)
        smfile = gtc_to_sim(sjson, manifest, smname, smargs, async)
        njson, cjson = parse_manifest(manifest, njname, cjname, args)
      end

      ilargs = {:size => chunk_size,
                :group_size => 50,
                :plink => true,
                :snps => njson}.merge(args)
      
      ilchunks = nil

      if cjson and smfile
        ilchunks = chromosome_bounds(cjson).collect { |cspec|
          chr = cspec['chromosome']
          pargs = {:chromosome => chr,
                   :start => cspec['start'],
                   :end => cspec['end']}
          
          call_from_sim_p(smfile, sjson, manifest, run_name + '.' + chr,
                          ilargs.merge(pargs), async)
        }.flatten

        unless ilchunks.all?
          ilchunks = nil
        end
      end

      ilfile = update_annotation(merge_bed(ilchunks, ilname, args, async),
                                 sjson, njson, args, async)

      output = 'illuminus_qc'
      qcargs = {:run => run_name, :sim => smfile}.merge(args)
      ilquality = quality_control(dbfile, ilfile, output, qcargs, async)

      if [gcsfile, ilfile, gcquality, ilquality].all?
         [gcsfile, ilfile, gcquality, ilquality]
      end
    end

    :private
    def chromosome_bounds(cjson)
      if cjson
        JSON.parse(File.read(cjson))
      else
        []
      end
    end
  end
end
