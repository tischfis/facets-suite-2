#!/usr/bin/env Rscript

##########################################################################################
##########################################################################################
# MSKCC CMO
# FACETS QC
##########################################################################################
##########################################################################################

'%!in%' <- function(x,y)!('%in%'(x,y))

catverbose <- function(...){
  cat(format(Sys.time(), "%Y%m%d %H:%M:%S |"), ..., "\n")
}

getSDIR <- function(){
  args=commandArgs(trailing=F)
  TAG="--file="
  path_idx=grep(TAG,args)
  SDIR=dirname(substr(args[path_idx],nchar(TAG)+1,nchar(args[path_idx])))
  if(length(SDIR)==0) {
    return(getwd())
  } else {
    return(SDIR)
  }
}

plot_vaf_by_cn_state <- function(maf, sample, wgd=F){
  if ('mcn' %!in% names(maf)){
    maf[, mcn := tcn-lcn]
  }
  maf.tmp <- maf[patient == sample & !is.na(mcn) & mcn <= 6]
  phi <- unique(maf.tmp[!is.na(purity)]$purity)
  if(length(phi) == 0){
    catverbose("No FACETS annotations!")
  } else {
    gg <- ggplot(maf.tmp, aes(x=VAF)) + 
      geom_histogram(col="black", fill="#41B6C4", lwd=1.5, binwidth = 0.02) +
      geom_vline(xintercept=(phi/2), linetype=2, color = "#FB6A4A") +
      facet_grid(lcn ~ mcn) + 
      xlab("Variant Allele Fraction") +
      ylab("Frequency") +
      ggtitle(sample) +
      theme_bw() + 
      theme(plot.title=element_text(size=25, face = "bold"),
            axis.title=element_text(size=20, face = "bold"),
            strip.text.x=element_text(size=20, face = "bold"),
            strip.text.y=element_text(size=20, face = "bold"),
            axis.text.x=element_text(size=15, angle=45, hjust=1),
            axis.text.y=element_text(size=15),
            legend.text=element_text(size=15),
            legend.title=element_text(size=15))
    if(wgd){
      gg <- gg + geom_vline(xintercept=(phi/4), linetype=2, color = "#FD8D3C")
    }
    plot(gg)
  }
}

center_igv_file <- function(outfile){
  
  igv.adj <- out$IGV
  
  if(out$dipLogR <= 0){igv.adj$seg.mean = igv.adj$seg.mean + abs(out$dipLogR)}
  if(out$dipLogR > 0){igv.adj$seg.mean = igv.adj$seg.mean - out$dipLogR}
  
  write.table(igv.adj, file = outfile, quote = F, row.names = F, col.names = T,
              sep = "\t")
  
}

facets_qc <- function(maf, facets, igv=F){
  
  summary <- c()
  flagged <- c()
  samples <- intersect(maf$Tumor_Sample_Barcode, facets$Tumor_Sample_Barcode)
  
  for (s in samples){
    
    cat('\n')
    catverbose(s)
    s.maf <- maf[Tumor_Sample_Barcode == s]
    s.facets <- facets[Tumor_Sample_Barcode == s]$Rdata_filename
    alt.fit <- F
  
    load(s.facets)
    catverbose("Loading FACETS Rdata...")
    facets.fit <- as.data.table(fit$cncf)
    
    purity <- fit$purity
    ploidy <- fit$ploidy
    catverbose(paste0("Purity: ", purity, " | ", "Ploidy: ", ploidy))
    
    n.bases <- sum(na.rm = T,as.numeric(fit$seglen))

    if(!is.null(out$flags)){
      alt.fit <- T
      catverbose(paste0("Flags: ", out$flags))
    }
    if(!is.na(purity)){
      if(purity < 0.3){
        catverbose(paste0("Purity < 0.3, use EM"))
      }
    }
    
    dipLogR <- out$dipLogR
    if(abs(dipLogR) > 1){
      alt.fit <- T
      catverbose(paste0("dipLogR magnitude > 1"))
    }
    
    # WGD
    wgd <- F
    f_hi_mcn <- sum(na.rm = T,as.numeric(fit$seglen[which((facets.fit$tcn - facets.fit$lcn) >= 2)])) / sum(na.rm = T,as.numeric(fit$seglen))
    if(!is.na(f_hi_mcn)){
      if(f_hi_mcn > 0.5){ # Major copy number >= 2 across 50% of the genome
        wgd <- T
        alt.fit <- T
        catverbose(paste0("Likely WGD"))
      }
    }
    
    # Balanced diploid region in WGD case 
    balance.thresh <- out$mafR.thresh
    if(wgd){
      dipLogR.bal.segs <- facets.fit[cnlr.median.clust == dipLogR & mafR.clust < balance.thresh]
      dipLogR.bal.chrs <- unique(dipLogR.bal.segs$chrom)
      dipLogR.bal.out <- paste(dipLogR.bal.chrs, collapse = "|")
      if(length(dipLogR.bal.chrs > 0)){
        catverbose("Balanced segments at dipLogR in chromosomes:")
        catverbose(dipLogR.bal.chrs)
      }
    }
    
    f_altered <- 0 # Fraction of genome altered
    f_altered_v2 <- 0 # Fraction of genome altered, excluding diploid regions in WGD cases
    if(wgd){
      cn.neutral <- sum(na.rm = T,as.numeric(fit$seglen[which(facets.fit$tcn == 4 & facets.fit$lcn == 2)]))
      cn.neutral.v2 <- sum(na.rm = T,as.numeric(fit$seglen[which((facets.fit$tcn == 4 & facets.fit$lcn == 2) | (facets.fit$tcn == 2 & facets.fit$lcn == 1))]))
      f_altered <- 1 - (cn.neutral / n.bases)
      f_altered_v2 <- 1 - (cn.neutral.v2 / n.bases)
    } else {
      cn.neutral <- sum(na.rm = T,as.numeric(fit$seglen[which(facets.fit$tcn == 2 & facets.fit$lcn == 1)]))
      f_altered <- f_altered_v2 <- 1 - (cn.neutral / n.bases)
    }
    
    # LOH
    loh <- sum(na.rm = T,as.numeric(fit$seglen[which(facets.fit$lcn == 0)])) / sum(na.rm = T,as.numeric(fit$seglen))
    if(!is.na(loh)){
      if(loh > 1/2){
        catverbose(paste0("Widespread LOH"))
      }
    }
    
    # Extreme amplifications and homozygous deletions
    n.amps <- nrow(facets.fit[tcn > 10])
    n.homdels <- nrow(facets.fit[tcn == 0])
    
    # Hypersegmentation / complex rearrangements
    chr.break <- F
    n.segments <- table(unique(facets.fit[, .(chrom, tcn, lcn)])[["chrom"]])
    if(any(n.segments >= 5)){ # 5 or more unique copy number states in a given chromosome 
      chr.break <- T
      chr.tmp <- names(which(table(unique(facets.fit[, .(chrom, tcn, lcn)])[["chrom"]]) > 5))
      catverbose("5+ unique CN states on chromosome(s):") 
      catverbose(chr.tmp)
    }
    
    bal.logR <- out$alBalLogR[, 'dipLogR']
    if(dipLogR %!in% bal.logR){
      catverbose("Unbalanced dipLogR")
    }
    
    if(alt.fit){
      alt.diplogR <- as.numeric(bal.logR[which(bal.logR != dipLogR)])
      catverbose(paste0("Alternative dipLogR: ", alt.diplogR))
    }
    
    # ggsave(plot_vaf_by_cn_state(s.maf, wgd), filename = paste0(s, "_vaf_vs_cn.pdf"),
    #        width = 20, height = 14)
    
    homloss.idx <- which(facets.fit$tcn == 0)
    facets.fit.homloss <- as.data.table(cbind(facets.fit$chrom[homloss.idx], 
                                              facets.fit$start[homloss.idx],
                                              facets.fit$end[homloss.idx])
                                        )
    
    setnames(facets.fit.homloss, c("Chromosome", "Start_Position", "End_Position"))
    setkey(facets.fit.homloss, Chromosome, Start_Position, End_Position)
    facets.fit.homloss <- facets.fit.homloss[Chromosome %in% seq(1,22)]
    
    s.maf.tmp <- s.maf[Chromosome %in% seq(1,22), .(Chromosome, Start_Position, End_Position)]
    s.maf.tmp[, Chromosome := as.numeric(Chromosome)]
    
    homloss.overlaps <- foverlaps(s.maf.tmp,
                                  facets.fit.homloss,
                                  type = "any")[!is.na(Start_Position)]
    n.homloss.overlaps <- nrow(homloss.overlaps)
    if(nrow(homloss.overlaps) > 0){
      catverbose(paste0("Mutations called in homozygous loss segments"))
    }
    
    facets.fit <- as.data.table(facets.fit)
    n.segment <- facets.fit[, .N]
    n.segment.NA.lcn <- facets.fit[is.na(lcn.em), .N]
    n.segment.altered <- facets.fit[tcn.em != 2 | lcn.em != 1, .N]
    frac_em_cncf_agreement_tcn <- facets.fit[tcn == tcn.em, sum(end - start)] / facets.fit[, sum(end - start)]
    n.snps <- facets.fit[, sum(num.mark)]
    n.het.snps <- facets.fit[, sum(nhet)]
    sd.clust <- facets.fit[, sd(cnlr.median - cnlr.median.clust)]
    
    jointseg <- as.data.table(out$jointseg)
    jointseg[, cnlr.residual :=  cnlr - median(cnlr), seg]
    sd.cnlr <- jointseg[, sd(cnlr)]
    mean.cnlr.residual <- jointseg[, mean(cnlr.residual)]
    sd.cnlr.residual <- jointseg[, sd(cnlr.residual)]
    
    loglik <- ifelse(!is.null(fit$loglik), fit$loglik, NA)
    
    if(igv){
      center_igv_file(outfile = paste0(s, "_igv.adj.seg"))
    }
    
    s.summary <-
      c(
        s,
        purity,
        ploidy,
        dipLogR,
        f_hi_mcn,
        wgd,
        f_altered_v2,
        loh,
        frac_em_cncf_agreement_tcn,
        n.segment,
        n.segment.NA.lcn,
        n.segment.altered,
        n.amps,
        n.homdels,
        n.snps,
        n.het.snps,
        n.homloss.overlaps,
        loglik,
        sd.clust,
        sd.cnlr,
        mean.cnlr.residual,
        sd.cnlr.residual
      )
    summary <- rbind(summary, s.summary)
    
    if(!is.null(out$flags)) {
      flags.out <- paste(out$flags, collapse = " | ")
       s.summary <- c(s.summary, flags.out)
      flagged <- rbind(flagged, s.summary) 
    } else { 
      s.summary <- c(s.summary, "")
      flagged <- rbind(flagged, s.summary) 
    }
    
  }
  
  colnames_summary <-
    c(
      'Tumor_Sample_Barcode',
      'Purity',
      'Ploidy',
      'dipLogR',
      'f_hi_MCN',
      'WGD',
      'FGA',
      'LOH',
      'frac_em_cncf_agreement_tcn',
      'n.segment',
      'n.segment.NA.lcn',
      'n.segment.altered',
      'Amps.n',
      'HomDels.n',
      'n.snps',
      'n.het.snps',
      'n.homloss.overlaps',
      'loglik',
      'sd.clust',
      'sd.cnlr',
      'mean.cnlr.residual',
      'sd.cnlr.residual',
      'Flags'
    )
  flagged <- as.data.table(flagged)
  setnames(flagged, colnames_summary)
  write.table(flagged, file="FACETS_QC_summary.txt", quote=F, row.names=F, col.names=T,
              sep="\t")
  
  # colnames(flagged) <- c(colnames_summary, )
  # write.table(flagged, file="FACETS_QC_flagged.txt", quote=F, row.names=F, col.names=T,
  #             sep="\t")
  

}

if ( ! interactive() ) {
  
  pkgs = c('data.table', 'argparse', 'RColorBrewer', 'ggplot2', 'grid')
  tmp <- lapply(pkgs, require, quietly=T, character.only = T)
  rm(tmp)
  #options(datatable.showProgress = FALSE)
  
  parser=ArgumentParser()
  parser$add_argument('-m', '--maf', required=T, type='character', help='MAF file with FACETS annotations')
  parser$add_argument('-f', '--facets', required=T, type='character', 
                      help='Mapping of "Tumor_Sample_Barcode" from maf and "Rdata_filename" from FACETS (tab-delimited with header)')
  parser$add_argument('-i', '--igv', action='store_true', default=F,
                      help='Output adjusted seg file for IGV')
  args=parser$parse_args()

  maf <- suppressWarnings(fread(paste0("grep -v '^#' ", args$maf)))
  maf[, patient := stringr::str_extract(Tumor_Sample_Barcode, "P-[0-9]{7}-T[0-9]{2}-IM[0-9]")]
  facets <- fread(args$facets)
  setnames(facets, c("Tumor_Sample_Barcode", "Rdata_filename"))
  igv <- args$igv
  
  sink('FACETS_QC.log')
  facets_qc(maf, facets, igv)
  sink()
  
}


