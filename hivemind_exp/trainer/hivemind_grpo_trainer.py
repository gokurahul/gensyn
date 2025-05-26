import gc
import hashlib
import logging
import time
import traceback
from typing import Any

import datasets
import torch
from hivemind.dht import DHT
from hivemind.utils import get_dht_time
from trl import GRPOConfig, GRPOTrainer

from hivemind_exp.debug_utils import print_system_info
from hivemind_exp.dht_utils import (
    ROUND_STAGE_NUMBER_KEY,
    get_dht_value,
    get_round_and_stage,
    leaderboard_key,
    node_outputs_key,
    rewards_key,
)
from hivemind_exp.hivemind_utils import HivemindNode, StageData
from hivemind_exp.name_utils import get_name_from_peer_id


MAX_TRAIN_FAILS = 5
CADENCE_OF_UPDATE_STEPS = 4


class HivemindGRPOTrainer:
    """
    Subclass of GRPOTrainer that implements multi-stage GRPO by publishing
    intermediate results to a connected Hivemind DHT.
    """

    class PublishingGRPOTrainer(GRPOTrainer):
        def __init__(
            self,
            node: HivemindNode,
            dht: DHT,
            tokenizer,
            logger,
            **kwargs,
        ):
            self.node = node
            self.dht = dht
            self.logger = logger
            self.stage_rewards = 0.0
            super().__init__(processing_class=tokenizer, **kwargs)

        def publish_leaderboard(self):
            r, s = self.node.round_num, self.node.stage_num
            curr_rewards: dict[str, Any] | None = get_dht_value(
                self.dht, key=rewards_key(r, s), latest=True
            )
            if curr_rewards:
                # Sorted list of (node_key, reward) pairs.
                leaderboard = list(
                    sorted(
                        curr_rewards.items(), key=lambda t: (t[1], t[0]), reverse=True
                    )
                )
                self.dht.store(
                    key=leaderboard_key(r, s),
                    value=leaderboard,
                    expiration_time=get_dht_time() + self.node.out_expiration,
                )
            else:
                self.logger.info(f"Can't retrieve round {r} stage {s -1} rewards") # Typo s -1 corrected to s - 1

        def compute_loss(self, model, inputs, *args, **kwargs):
            loss = super().compute_loss(model, inputs, *args, **kwargs)
            # Reward function must save node.outputs + node.rewards!
            # This is only here to publish to the DHT at the right time.
            # Only publish to DHT every N steps
            if self.state.global_step % CADENCE_OF_UPDATE_STEPS == 0:
                # Ensure node.outputs exists and has "question" key
                if hasattr(self.node, 'outputs') and self.node.outputs and "question" in self.node.outputs:
                    question = self.node.outputs["question"]
                    q_hash = hashlib.md5(question.encode()).hexdigest()

                    value = (time.time(), self.node.outputs)
                    self.dht.store(
                        key=node_outputs_key(self.node),
                        subkey=q_hash,
                        value=value,
                        expiration_time=get_dht_time() + self.node.out_expiration,
                    )
                    self.node.put_stage_outputs(
                        self.node.round_num, self.node.stage_num, q_hash, value
                    )

                    # Ensure node.rewards exists and is iterable
                    if hasattr(self.node, 'rewards') and isinstance(self.node.rewards, (list, tuple)):
                        self.stage_rewards += sum(self.node.rewards)
                    else:
                        self.logger.warning("node.rewards is not available or not iterable for calculating stage_rewards.")

                    self.dht.store(
                        key=rewards_key(self.node.round_num, self.node.stage_num),
                        subkey=self.node.key,
                        value=self.stage_rewards,
                        expiration_time=get_dht_time() + self.node.out_expiration,
                    )
                else:
                    self.logger.warning("node.outputs not available or 'question' key missing, skipping DHT publish for outputs.")

            if self.node.is_coordinator:
                self.publish_leaderboard()

            return loss

    def __init__(
        self,
        node: HivemindNode,
        dht: DHT,
        stage_data: StageData,
        config: GRPOConfig,
        model,
        tokenizer,
        log_tag=None,
        **kwargs,
    ):
        # The single coordinator is responsible for incrementing round + stage numbers.
        # TODO(lou): Allow ability to choose different coordinators?
        self.node = node
        self.dht = dht

        self.stage_data = stage_data

        self.config = config
        self.config.dataloader_num_workers = 0  # Default: 8+
        assert self.config.output_dir
        self.config.output_dir += f"-{get_name_from_peer_id(self.node.key, True)}"  # TODO: Add animal name to save path in more appropriate spot
        self.model = model
        self.tokenizer = tokenizer
        if tokenizer.pad_token is None:
            tokenizer.pad_token = tokenizer.eos_token

        if not log_tag:
            log_tag = self.node.key

        self.logger = logging.getLogger(f"{__name__}:{log_tag}")

    def wait_for(self, result_fn=lambda: None, interval=10, timeout=30):
        start_time = time.monotonic()
        while time.monotonic() - start_time < timeout:
            result = result_fn()
            if result is None:
                time.sleep(interval)
            else:
                break

        return result

    def _create_publishing_trainer(self, kwargs: dict):
        return HivemindGRPOTrainer.PublishingGRPOTrainer(
            self.node, self.dht, self.tokenizer, self.logger, **kwargs
        )

    def train_stages(self, round_num, start_stage, is_coordinator):
        # TODO: Needs checkpoint loading
        self.node.round_num = round_num
        for i, stage in enumerate(self.stage_data.stages[start_stage:]):
            stage_num = start_stage + i
            self.node.stage_num = stage_num

            if is_coordinator:
                self.dht.store(
                    key=ROUND_STAGE_NUMBER_KEY,
                    value=(self.node.round_num, stage_num),
                    expiration_time=get_dht_time() + self.node.out_expiration,
                )

            self.logger.info(f"📈 Training round: {round_num} stage: {stage_num}")
            train_dataset, test_dataset = stage.datasets_fn(round_num, stage_num)

            # ===== MULAI BLOK KODE DEBUGGING =====
            self.logger.info("===== MEMULAI INSPEKSI train_dataset =====")
            if train_dataset is None:
                self.logger.error("FATAL: train_dataset adalah None setelah pemanggilan stage.datasets_fn!")
            else:
                self.logger.info(f"Tipe train_dataset: {type(train_dataset)}")
                try:
                    # Cek apakah dataset memiliki panjang (untuk Dataset standar)
                    if hasattr(train_dataset, '__len__'):
                        dataset_len = len(train_dataset)
                        self.logger.info(f"Jumlah sampel di train_dataset: {dataset_len}")

                        if dataset_len == 0:
                            self.logger.warning("PERINGATAN: train_dataset kosong (jumlah sampel 0)!")
                        else:
                            num_samples_to_check = min(5, dataset_len) # Periksa hingga 5 sampel
                            self.logger.info(f"Memeriksa {num_samples_to_check} sampel pertama dari train_dataset:")
                            for idx in range(num_samples_to_check):
                                try:
                                    sample = train_dataset[idx]
                                    self.logger.info(f"  Sampel [{idx}]: {sample}")
                                    if sample is None:
                                        self.logger.error(f"  FATAL: Sampel [{idx}] dari train_dataset adalah None!")
                                    elif isinstance(sample, dict):
                                        if "labels" not in sample:
                                            self.logger.warning(f"  PERINGATAN: Sampel [{idx}] tidak memiliki field 'labels'. Keys yang ada: {list(sample.keys())}")
                                        elif sample["labels"] is None:
                                            self.logger.warning(f"  PERINGATAN: Sampel [{idx}] field 'labels'-nya adalah None.")
                                    else:
                                        self.logger.warning(f"  PERINGATAN: Sampel [{idx}] bukan dictionary, tipenya: {type(sample)}")
                                except Exception as e:
                                    self.logger.error(f"  ERROR saat mengakses atau memeriksa sampel [{idx}] dari train_dataset: {e}", exc_info=True)
                    # Jika dataset adalah IterableDataset (tidak memiliki __len__ atau __len__ mengembalikan error)
                    elif isinstance(train_dataset, torch.utils.data.IterableDataset):
                        self.logger.warning("train_dataset adalah IterableDataset. Mencoba mengambil satu sampel...")
                        # PENTING: Mengiterasi IterableDataset di sini akan mengkonsumsi item.
                        # Ini hanya untuk debugging cepat. Untuk training sebenarnya, Anda mungkin perlu
                        # membuat ulang iterator atau dataset jika state iterator penting.
                        try:
                            iterator = iter(train_dataset)
                            first_sample = next(iterator)
                            self.logger.info(f"  Sampel pertama (dari IterableDataset): {first_sample}")
                            if first_sample is None:
                                 self.logger.error(f"  FATAL: Sampel pertama (dari IterableDataset) adalah None!")
                            elif isinstance(first_sample, dict):
                                if "labels" not in first_sample:
                                    self.logger.warning(f"  PERINGATAN: Sampel pertama (dari IterableDataset) tidak memiliki field 'labels'. Keys yang ada: {list(first_sample.keys())}")
                                elif first_sample["labels"] is None:
                                     self.logger.warning(f"  PERINGATAN: Sampel pertama (dari IterableDataset) field 'labels'-nya adalah None.")
                            else:
                                self.logger.warning(f"  PERINGATAN: Sampel pertama (dari IterableDataset) bukan dictionary, tipenya: {type(first_sample)}")
                            # Catatan: setelah `next(iterator)`, iterator sudah maju. Jika dataset ini akan dipakai langsung
                            # oleh DataLoader, sampel pertama ini sudah terlewat.
                            # Untuk debugging, ini mungkin OK, tapi untuk training, pertimbangkan implikasinya.
                        except StopIteration:
                            self.logger.error("FATAL: train_dataset (IterableDataset) tidak menghasilkan sampel (kosong).")
                        except Exception as e:
                            self.logger.error(f"  ERROR saat mencoba mengambil sampel pertama dari IterableDataset: {e}", exc_info=True)
                    else:
                        self.logger.warning("Tipe train_dataset tidak diketahui atau tidak memiliki __len__.")

                except Exception as e: # Menangkap error umum saat inspeksi dataset
                     self.logger.error(f"ERROR saat melakukan inspeksi umum pada train_dataset (misalnya saat memanggil len()): {e}", exc_info=True)
            self.logger.info("===== SELESAI INSPEKSI train_dataset =====")
            # ===== SELESAI BLOK KODE DEBUGGING =====

            trainer = self._create_publishing_trainer(
                {
                    "model": self.model,
                    "args": self.config,
                    "reward_funcs": stage.reward_funcs,
                    "train_dataset": train_dataset,
                    "eval_dataset": test_dataset,
                }
            )
            self.train_stage_and_save(trainer, train_dataset)
            self.logger.info(
                f"📉 Finished training round: {round_num} stage: {stage_num}"
            )

        # Push to HF hub if desired
        # TODO: Come back and add additional logic checking if they've provided access token+HF username
        if self.config.push_to_hub_token is not None:
            self.logger.info("Pushing model to Hugging Face Hub...")
            try:
                trainer.push_to_hub(
                    tags=[
                        "rl-swarm",
                        "grpo",
                        "gensyn",
                        f"I am {get_name_from_peer_id(self.node.key)}",
                    ]
                )
                time.sleep(1)
            except Exception:
                self.logger.info(
                    "Failed to push model to the Hugging Face Hub. When you conclude training please try manually pushing it yourself using the instructions here: https://huggingface.co/docs/hub/en/models-uploading"
                )

        self.cleanup()

        del trainer
        gc.collect()

    def cleanup(self):
        # Clear various stage caches.
        gc.collect()
        if torch.cuda.is_available():
            torch.cuda.empty_cache()
            torch.cuda.ipc_collect()
        if torch.backends.mps.is_available():  # type: ignore
            torch.mps.empty_cache()  # type: ignore
        try:
            if torch.xpu.is_available():  # type: ignore
                torch.xpu.empty_cache()  # type: ignore
        except AttributeError:
            pass

        self.node.clear_stage_cache()

    def train_stage_and_save(self, trainer, train_dataset):
        train_result = None # Inisialisasi train_result
        for attempt in range(MAX_TRAIN_FAILS):
            try:
                train_result = trainer.train()
                break  # Jika berhasil, keluar dari loop
            except (BlockingIOError, EOFError) as e:
                self.logger.warning(f"DHT IPC error (attempt {attempt + 1}/{MAX_TRAIN_FAILS}): {e}. Restarting training stage in 5s...")
                self.cleanup()  # Clear GPU/caches
                time.sleep(5)
                if attempt == MAX_TRAIN_FAILS - 1:
                    self.logger.error(f"DHT IPC error: Failed after {MAX_TRAIN_FAILS} attempts. Raising exception.")
                    raise # Lemparkan exception setelah gagal maksimal
                continue # Lanjutkan ke percobaan berikutnya
            except Exception as e: # Menangkap error lain yang mungkin terjadi selama trainer.train()
                self.logger.error(f"Unexpected error during trainer.train() (attempt {attempt + 1}/{MAX_TRAIN_FAILS}): {e}", exc_info=True)
                self.cleanup()
                time.sleep(5)
                if attempt == MAX_TRAIN_FAILS - 1:
                    self.logger.error(f"Unexpected error: Failed after {MAX_TRAIN_FAILS} attempts. Raising exception.")
                    raise
                continue


        # Pastikan train_result tidak None sebelum mengakses metrics
        if train_result is None:
            self.logger.error("train_result is None after training attempts, skipping metrics logging and saving.")
            # Anda mungkin ingin menangani kasus ini lebih lanjut, misalnya dengan melemparkan error
            # atau menghentikan proses jika training dianggap gagal total.
            # Untuk sekarang, kita hanya log dan tidak melanjutkan dengan saving metrics/model.
            return

        # Log and save metrics
        metrics = train_result.metrics
        # Pastikan train_dataset punya __len__ sebelum memanggil len()
        if hasattr(train_dataset, '__len__'):
            metrics["train_samples"] = len(train_dataset)
        else:
            metrics["train_samples"] = "unknown (IterableDataset)" # Atau cara lain untuk menandai ini
        trainer.log_metrics("train", metrics)
        trainer.save_metrics("train", metrics)
        trainer.save_state()

        self.logger.info("Saving model")
        if hasattr(trainer, 'model') and trainer.model is not None and hasattr(trainer.model, 'config'):
            trainer.model.config.use_cache = True
        trainer.save_model(self.config.output_dir)
        self.logger.info(f"Model saved to {self.config.output_dir}")
        
        if hasattr(self.config, 'distributed_state') and self.config.distributed_state is not None:
            assert self.config.distributed_state # Ini sudah ada sebelumnya, tapi pastikan lagi
            self.config.distributed_state.wait_for_everyone()  # wait for all processes to load
        else:
            self.logger.warning("distributed_state not found in config or is None. Skipping wait_for_everyone().")


        self.tokenizer.save_pretrained(self.config.output_dir)
        self.logger.info(f"Tokenizer saved to {self.config.output_dir}")

    def get_round_and_stage(self):
        return get_round_and_stage(self.dht)

    def coordinator_train(self):
        round_num = 0
        start_time = time.monotonic()
        while (
            round_num < self.stage_data.max_rounds
            and time.monotonic() - start_time < self.stage_data.train_timeout
        ):
            self.logger.info(f"🤖 Starting new round: {round_num}")

            _ = self.dht.get_visible_maddrs(latest=True)
            self.train_stages(round_num, 0, is_coordinator=True)

            round_num += 1
            if round_num == self.stage_data.max_rounds:
                self.logger.info(f"Coordinator reached max_rounds ({self.stage_data.max_rounds}). Training finished.")
                return

        self.logger.info("Training timed out for coordinator!")

    def follower_train(
        self, check_interval=5.0, log_timeout=10.0, max_check_interval=60.0 * 5
    ):
        done_rounds = set()
        start_time = time.monotonic()
        fetch_log_time = start_time
        check_backoff = (
            check_interval  # Exponential backoff for already finished rounds.
        )
        while time.monotonic() - start_time < self.stage_data.train_timeout:
            curr_time = time.monotonic()
            _ = self.dht.get_visible_maddrs(latest=True)

            # Retrieve current round and stage.
            try:
                round_num, stage = self.get_round_and_stage()
                if round_num is None or stage is None: # Tambahan cek jika get_round_and_stage bisa mengembalikan None
                    if curr_time - fetch_log_time > log_timeout:
                        self.logger.debug(
                            f"Could not fetch valid round and stage (received None). Next check in {check_interval}s."
                        )
                        fetch_log_time = curr_time
                    time.sleep(check_interval)
                    continue
            except Exception as e:
                if curr_time - fetch_log_time > log_timeout:
                    self.logger.debug(
                        f"Could not fetch round and stage: {e}. Next check in {check_interval}s."
                    )
                    fetch_log_time = curr_time

                time.sleep(check_interval)
                continue

            if round_num not in done_rounds:
                self.logger.info(
                    f"🐝 Joining round: {round_num} starting at stage: {stage}"
                )
                try:
                    self.train_stages(round_num, stage, is_coordinator=False)
                except datasets.exceptions.DatasetGenerationError as dge: # Lebih spesifik menangkap error dataset
                    self.logger.warning(f"DatasetGenerationError in round {round_num}, stage {stage}: {dge}")
                    if stage > 0:
                        self.logger.info("Re-attempting training for round {round_num} starting at stage 0!")
                        # Start over from stage 0.
                        self.train_stages(round_num, 0, is_coordinator=False)
                    else:
                        self.logger.error(f"DatasetGenerationError at stage 0 for round {round_num}. Cannot recover this round. Skipping.")
                        # Tidak raise, tapi menandai round selesai agar tidak dicoba terus menerus
                        # dan menunggu round berikutnya.
                except Exception as e_train: # Menangkap error umum lainnya selama train_stages
                    self.logger.error(f"Unexpected error during train_stages for round {round_num}, stage {stage}: {e_train}", exc_info=True)
                    # Bisa jadi menandai round ini gagal dan lanjut, atau raise jika fatal.
                    # Untuk sekarang, kita anggap round ini gagal dan akan menunggu update round berikutnya.
                
                # Tandai round selesai (baik sukses maupun gagal setelah retry) agar tidak diulang tanpa henti
                done_rounds.add(round_num)
                check_backoff = check_interval  # Reset backoff after attempting a round
            else:
                if curr_time - fetch_log_time > log_timeout: # Log periodik meski round sudah selesai
                    self.logger.info(
                        f"Already finished round: {round_num}. Waiting for next round. Next check in {check_backoff}s."
                    )
                    fetch_log_time = curr_time # Reset log time agar tidak spam
                time.sleep(check_backoff)
                check_backoff = min(check_backoff * 2, max_check_interval)

            if round_num >= self.stage_data.max_rounds -1 : # Jika round terakhir sudah dicoba (selesai atau gagal)
                self.logger.info(f"Follower has attempted/finished the final round ({round_num}). Exiting training process.")
                return

        self.logger.info("Training timed out for follower!")

    def _train(self):
        if self.node.is_coordinator:
            self.coordinator_train()
        else:
            self.follower_train()

    def train(self):
        try:
            self._train()

        except Exception:
            self.logger.error("Encountered error during training!")
            print_system_info()
            traceback.print_exc()
            raise
